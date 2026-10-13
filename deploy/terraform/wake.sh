#!/usr/bin/env bash
# After-hours wake: start the DroneFeed EC2 for N hours (max 12).
#
# If the wake window hits a weekday business-hours start (or you wake during
# business hours), the weekday schedule takes over: no one-shot wake stop;
# the instance stays up until the weekday stop hour.
# Otherwise a one-shot stop fires after N hours.
#
# Usage:
#   ./wake.sh 4|8|12
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
Usage: $0 [options] <hours>
       $0 [options] --status
       $0 [options] --restore-schedule

  hours                   1–12 (typical: 4, 8, or 12)
  -p, --aws-profile NAME  AWS shared profile (same as setup.sh / destroy.sh)
  -h, --help              Show this help

Starts the Terraform-managed EC2 out of hours. Max 12h one-shot wake.
If a weekday business-hours start falls inside the wake window (or you wake
during business hours), the weekday stop schedule owns shutdown instead —
the box stays up until the normal end-of-day stop, not the wake expiry.
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
    *)
      if [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 12)); then
        ACTION=wake
        HOURS=$((10#$1))
        shift
      else
        die "unknown argument: $1 (hours must be 1–12; try --help)"
      fi
      ;;
  esac
done

[[ -n "$ACTION" ]] || { usage; exit 1; }

aws_profile_export "$AWS_PROFILE_ARG"
need_cmd aws
need_cmd terraform
need_cmd jq
need_cmd date
need_cmd python3

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
SCHED_TZ="$(tf_out schedule_timezone)"
SCHED_START="$(tf_out schedule_start_hour)"
SCHED_STOP="$(tf_out schedule_stop_hour)"
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

delete_schedule_if_exists() {
  local name="$1"
  if aws scheduler get-schedule --name "$name" --group-name default >/dev/null 2>&1; then
    aws scheduler delete-schedule --name "$name" --group-name default >/dev/null
    echo "Removed one-shot schedule $name"
  fi
}

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

# Exit 0 if weekday schedule should own shutdown (no wake one-shot stop).
schedule_takes_over() {
  local hours="$1"
  [[ -n "$SCHED_TZ" && "$SCHED_TZ" != "null" ]] || return 1
  [[ -n "$SCHED_START" && "$SCHED_START" != "null" ]] || return 1
  [[ -n "$SCHED_STOP" && "$SCHED_STOP" != "null" ]] || return 1
  HOURS="$hours" TZ_NAME="$SCHED_TZ" START_H="$SCHED_START" STOP_H="$SCHED_STOP" python3 - <<'PY'
from datetime import datetime, timedelta, time
from zoneinfo import ZoneInfo
import os, sys

hours = int(os.environ["HOURS"])
tz = ZoneInfo(os.environ["TZ_NAME"])
start_h = int(os.environ["START_H"])
stop_h = int(os.environ["STOP_H"])
now = datetime.now(tz)
wake_end = now + timedelta(hours=hours)

d = now.date()
end_d = wake_end.date()
one = timedelta(days=1)
while d <= end_d:
    if d.weekday() < 5:  # Mon–Fri
        start_dt = datetime.combine(d, time(start_h, 0), tzinfo=tz)
        stop_dt = datetime.combine(d, time(stop_h, 0), tzinfo=tz)
        # Weekday start fires while wake is still active → schedule owns the day.
        if now < start_dt < wake_end:
            sys.exit(0)
        # Already inside today's business window → weekday stop owns shutdown.
        if start_dt <= now < stop_dt:
            sys.exit(0)
    d += one
sys.exit(1)
PY
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
  if [[ -n "$SCHED_TZ" && "$SCHED_TZ" != "null" ]]; then
    echo "Business hours: Mon–Fri ${SCHED_START}:00→${SCHED_STOP}:00 $SCHED_TZ"
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

PUBLIC_IP="$(tf_out public_ip)"
HANDOFF=false
if schedule_takes_over "$HOURS"; then
  HANDOFF=true
fi

if [[ "$HANDOFF" == true ]]; then
  # Weekday schedule owns power from here: keep stop enabled, drop any wake one-shot.
  restore_weekday_stop
  delete_schedule_if_exists "$WAKE_STOP_NAME"
  delete_schedule_if_exists "$WAKE_RESTORE_NAME"
  echo
  echo "Wake → weekday schedule takes over"
  echo "  Instance:     $INSTANCE_ID"
  echo "  App URL:      http://${PUBLIC_IP}"
  echo "  Requested:    ${HOURS}h wake (would have ended ${STOP_AT}Z)"
  echo "  Shutdown:     weekday stop ${SCHED_STOP}:00 ${SCHED_TZ} (not the wake timer)"
  echo "  Business hrs: Mon–Fri ${SCHED_START}:00→${SCHED_STOP}:00 ${SCHED_TZ}"
  echo
  show_status
  exit 0
fi

# Pure out-of-hours wake: one-shot stop after N hours.
# Pause weekday stop only if it is enabled (so a same-day stop cannot cut the wake short);
# restore it when the wake ends.
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

echo
echo "Wake armed for ${HOURS}h (max 12)"
echo "  Instance:  $INSTANCE_ID"
echo "  App URL:   http://${PUBLIC_IP}"
echo "  Stops at:  ${STOP_AT}Z (one-shot $WAKE_STOP_NAME)"
echo "  No weekday start in this window — using wake timer."
echo
show_status
