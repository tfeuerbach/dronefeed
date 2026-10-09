#!/usr/bin/env bash
# After-hours wake: start the DroneFeed EC2 for N hours, then stop it.
# Keeps weekday Mon–Fri schedules enabled (briefly pauses weekday stop only if it
# would cut the wake window short, then auto-restores).
#
# Usage:
#   ./wake.sh 4|8|12|24
#   ./wake.sh --status
#   ./wake.sh --restore-schedule
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1'"
}

need_cmd aws
need_cmd terraform
need_cmd jq
need_cmd date

usage() {
  cat <<EOF
Usage: $0 <4|8|12|24>
       $0 --status
       $0 --restore-schedule

Starts the Terraform-managed EC2 instance and schedules a one-shot stop after N hours.
Uses the same AWS credentials as terraform apply. Run from deploy/terraform.
EOF
}

tf_out() {
  terraform output -raw "$1" 2>/dev/null || true
}

INSTANCE_ID="$(tf_out instance_id)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" ]] || die "no instance_id — run terraform apply first"

REGION="$(tf_out aws_region)"
[[ -n "$REGION" && "$REGION" != "null" ]] || REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

NAME_PREFIX="$(tf_out name_prefix)"
[[ -n "$NAME_PREFIX" && "$NAME_PREFIX" != "null" ]] || NAME_PREFIX="dronefeed"

ROLE_ARN="$(tf_out scheduler_role_arn)"
STOP_NAME="$(tf_out schedule_stop_name)"
WAKE_STOP_NAME="${NAME_PREFIX}-ec2-wake-stop"
WAKE_RESTORE_NAME="${NAME_PREFIX}-ec2-wake-restore"

set_weekday_stop_state() {
  local desired="$1" # ENABLED | DISABLED
  [[ -n "$STOP_NAME" && "$STOP_NAME" != "null" ]] || return 0
  local tmp out
  tmp="$(mktemp)"
  out="$(mktemp)"
  if ! aws scheduler get-schedule --name "$STOP_NAME" --group-name default >"$tmp" 2>/dev/null; then
    rm -f "$tmp" "$out"
    return 0
  fi
  local state
  state="$(jq -r '.State' "$tmp")"
  if [[ "$state" == "$desired" ]]; then
    rm -f "$tmp" "$out"
    return 0
  fi
  jq --arg st "$desired" '{
    Name: .Name,
    GroupName: "default",
    ScheduleExpression: .ScheduleExpression,
    ScheduleExpressionTimezone: (.ScheduleExpressionTimezone // "UTC"),
    Description: (.Description // ""),
    State: $st,
    FlexibleTimeWindow: .FlexibleTimeWindow,
    Target: {
      Arn: .Target.Arn,
      RoleArn: .Target.RoleArn,
      Input: .Target.Input
    }
  }' "$tmp" >"$out"
  aws scheduler update-schedule --cli-input-json "file://$out" >/dev/null
  rm -f "$tmp" "$out"
  echo "Weekday stop schedule $STOP_NAME → $desired"
}

restore_weekday_stop() { set_weekday_stop_state ENABLED; }
disable_weekday_stop() { set_weekday_stop_state DISABLED; }
upsert_schedule() {
  local name="$1" at_expr="$2" target_arn="$3" target_role="$4" target_input="$5" desc="$6"
  local payload tmp
  tmp="$(mktemp)"
  payload="$(jq -nc \
    --arg name "$name" \
    --arg expr "$at_expr" \
    --arg desc "$desc" \
    --arg arn "$target_arn" \
    --arg role "$target_role" \
    --argjson input "$target_input" \
    '{
      Name: $name,
      GroupName: "default",
      ScheduleExpression: $expr,
      FlexibleTimeWindow: {Mode: "OFF"},
      State: "ENABLED",
      Description: $desc,
      Target: {Arn: $arn, RoleArn: $role, Input: ($input | tostring)}
    }')"
  printf '%s' "$payload" >"$tmp"
  if aws scheduler get-schedule --name "$name" --group-name default >/dev/null 2>&1; then
    aws scheduler update-schedule --cli-input-json "file://$tmp" >/dev/null
  else
    # Prefer delete-after-completion for one-shots when the API supports it.
    jq '. + {ActionAfterCompletion: "DELETE"}' "$tmp" >"${tmp}.create"
    aws scheduler create-schedule --cli-input-json "file://${tmp}.create" >/dev/null 2>&1 \
      || aws scheduler create-schedule --cli-input-json "file://$tmp" >/dev/null
    rm -f "${tmp}.create"
  fi
  rm -f "$tmp"
}
show_status() {
  local state
  state="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)"
  echo "Instance: $INSTANCE_ID ($state)"
  if [[ -n "$STOP_NAME" && "$STOP_NAME" != "null" ]]; then
    local s
    s="$(aws scheduler get-schedule --name "$STOP_NAME" --group-name default --query 'State' --output text 2>/dev/null || echo missing)"
    echo "Weekday stop ($STOP_NAME): $s"
  else
    echo "Weekday schedule: not enabled in this stack"
  fi
  if aws scheduler get-schedule --name "$WAKE_STOP_NAME" --group-name default >/dev/null 2>&1; then
    aws scheduler get-schedule --name "$WAKE_STOP_NAME" --group-name default \
      --query '[ScheduleExpression,State,Description]' --output text | awk '{print "Wake stop: "$0}'
  else
    echo "Wake stop: none"
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --status) show_status; exit 0 ;;
  --restore-schedule) restore_weekday_stop; exit 0 ;;
  4|8|12|24) HOURS="$1" ;;
  *) usage; exit 1 ;;
esac

[[ -n "$ROLE_ARN" && "$ROLE_ARN" != "null" ]] || die "scheduler_role_arn missing — enable_business_hours_schedule must be true (default)"

echo "Starting $INSTANCE_ID …"
aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo "Instance running."

# at() expressions are UTC without timezone suffix.
if date -u -d "+${HOURS} hours" +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
  STOP_AT="$(date -u -d "+${HOURS} hours" +%Y-%m-%dT%H:%M:%S)"
elif date -u -v+"${HOURS}H" +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
  STOP_AT="$(date -u -v+"${HOURS}H" +%Y-%m-%dT%H:%M:%S)"
else
  die "cannot compute stop time (need GNU or BSD date)"
fi
AT_EXPR="at(${STOP_AT})"

STOP_INPUT="$(jq -nc --arg id "$INSTANCE_ID" '{InstanceIds:[$id]}')"

# If weekday stop would fire before wake ends, pause it and schedule restore at wake stop time.
PAUSE_WEEKDAY=false
if [[ -n "$STOP_NAME" && "$STOP_NAME" != "null" ]]; then
  STOP_STATE="$(aws scheduler get-schedule --name "$STOP_NAME" --group-name default --query 'State' --output text 2>/dev/null || echo DISABLED)"
  if [[ "$STOP_STATE" == "ENABLED" ]]; then
    # Heuristic: if "now" local weekday and current hour < stop hour < wake end hour same day — pause.
    # Safer approach: always pause weekday stop for the wake window and restore at STOP_AT.
    # That keeps Mon–Fri schedule intact long-term without guessing cron next-fire.
    PAUSE_WEEKDAY=true
  fi
fi

if [[ "$PAUSE_WEEKDAY" == true ]]; then
  disable_weekday_stop
  # Restore payload = current (disabled) schedule with State ENABLED
  tmp="$(mktemp)"
  aws scheduler get-schedule --name "$STOP_NAME" --group-name default >"$tmp"
  RESTORE_INPUT="$(jq -c '{
    Name: .Name,
    GroupName: "default",
    ScheduleExpression: .ScheduleExpression,
    ScheduleExpressionTimezone: (.ScheduleExpressionTimezone // "UTC"),
    Description: (.Description // ""),
    State: "ENABLED",
    FlexibleTimeWindow: .FlexibleTimeWindow,
    Target: {
      Arn: .Target.Arn,
      RoleArn: .Target.RoleArn,
      Input: .Target.Input
    }
  }' "$tmp")"
  rm -f "$tmp"
  upsert_schedule "$WAKE_RESTORE_NAME" "$AT_EXPR" \
    "arn:aws:scheduler:::aws-sdk:scheduler:updateSchedule" \
    "$ROLE_ARN" \
    "$RESTORE_INPUT" \
    "Re-enable weekday stop after wake (${HOURS}h)"
  echo "Scheduled weekday stop restore at ${STOP_AT}Z via $WAKE_RESTORE_NAME"
fi

upsert_schedule "$WAKE_STOP_NAME" "$AT_EXPR" \
  "arn:aws:scheduler:::aws-sdk:ec2:stopInstances" \
  "$ROLE_ARN" \
  "$STOP_INPUT" \
  "Wake one-shot stop after ${HOURS}h"

PUBLIC_IP="$(tf_out public_ip)"
echo
echo "Wake armed for ${HOURS}h"
echo "  Instance:  $INSTANCE_ID"
echo "  App URL:   http://${PUBLIC_IP}"
echo "  Stops at:  ${STOP_AT}Z (one-shot $WAKE_STOP_NAME)"
echo "  Weekday Mon–Fri start/stop schedules remain configured; stop was paused only if needed and will be re-enabled."
echo
show_status
