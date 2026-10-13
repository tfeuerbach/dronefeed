#!/usr/bin/env bash
# After-hours wake: start the DroneFeed EC2 for N hours, then stop it.
# Keeps weekday Mon–Fri schedules enabled (briefly pauses weekday stop only if it
# would cut the wake window short, then auto-restores).
#
# Usage:
#   ./wake.sh 4|8|12|24
#   ./wake.sh -p spectre 4
#   ./wake.sh --status
#   ./wake.sh --restore-schedule
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# shellcheck source=aws_profile.inc.sh
source "$ROOT/aws_profile.inc.sh"

die() { echo "error: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1'"
}

usage() {
  cat <<EOF
Usage: $0 [options] <4|8|12|24>
       $0 [options] --status
       $0 [options] --restore-schedule

  -p, --aws-profile NAME  AWS shared profile (same as setup.sh / destroy.sh)
  -h, --help              Show this help

Starts the Terraform-managed EC2 instance and schedules a one-shot stop after N hours.
Run from deploy/terraform with the same profile you used for apply.
EOF
}

AWS_PROFILE_ARG=""
ACTION=""
HOURS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--aws-profile)
      [[ $# -ge 2 ]] || die "$1 requires a profile name"
      AWS_PROFILE_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --status)
      ACTION=status
      shift
      ;;
    --restore-schedule)
      ACTION=restore
      shift
      ;;
    4|8|12|24)
      ACTION=wake
      HOURS="$1"
      shift
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

[[ -n "$ACTION" ]] || { usage; exit 1; }

aws_profile_export "$AWS_PROFILE_ARG"
need_cmd aws
need_cmd terraform
need_cmd jq
need_cmd date

if [[ -n "$AWS_PROFILE_ARG" ]]; then
  aws_profile_require "$AWS_PROFILE_ARG"
fi

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

case "$ACTION" in
  status) show_status; exit 0 ;;
  restore) restore_weekday_stop; exit 0 ;;
  wake) ;;
  *) die "internal: bad action $ACTION" ;;
esac

[[ -n "$ROLE_ARN" && "$ROLE_ARN" != "null" ]] || die "scheduler_role_arn missing — enable_business_hours_schedule must be true (default)"

echo "Starting $INSTANCE_ID …"
aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo "Instance running."

if date -u -d "+${HOURS} hours" +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
  STOP_AT="$(date -u -d "+${HOURS} hours" +%Y-%m-%dT%H:%M:%S)"
elif date -u -v+"${HOURS}H" +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
  STOP_AT="$(date -u -v+"${HOURS}H" +%Y-%m-%dT%H:%M:%S)"
else
  die "cannot compute stop time (need GNU or BSD date)"
fi
AT_EXPR="at(${STOP_AT})"

STOP_INPUT="$(jq -nc --arg id "$INSTANCE_ID" '{InstanceIds:[$id]}')"

PAUSE_WEEKDAY=false
if [[ -n "$STOP_NAME" && "$STOP_NAME" != "null" ]]; then
  STOP_STATE="$(aws scheduler get-schedule --name "$STOP_NAME" --group-name default --query 'State' --output text 2>/dev/null || echo DISABLED)"
  if [[ "$STOP_STATE" == "ENABLED" ]]; then
    PAUSE_WEEKDAY=true
  fi
fi

if [[ "$PAUSE_WEEKDAY" == true ]]; then
  disable_weekday_stop
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
