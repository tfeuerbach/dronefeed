#!/usr/bin/env bash
# Push aggregated disk/swap CW Agent config to a running DroneFeed host.
# user_data is ignored after first boot — run once after changing agent JSON.
#
#   export AWS_PROFILE=spectre
#   cd deploy/terraform && ./scripts/refresh-cw-agent.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INSTANCE_ID="${1:-$(terraform output -raw instance_id 2>/dev/null || true)}"
NAME_PREFIX="$(terraform output -raw name_prefix 2>/dev/null || echo dronefeed)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" ]] || {
  echo "error: pass instance id or ensure terraform output instance_id works" >&2
  exit 1
}

CFG="$(mktemp)"
trap 'rm -f "$CFG"' EXIT

cat >"$CFG" <<EOF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "\${aws:InstanceId}"
    },
    "aggregation_dimensions": [
      ["InstanceId"],
      ["InstanceId", "path"]
    ],
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "swap": { "measurement": ["swap_used_percent"] },
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"],
        "drop_device": true,
        "ignore_file_system_types": ["sysfs", "devtmpfs", "tmpfs", "overlay", "nsfs"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/opt/drone-feed/compose-bootstrap.log",
            "log_group_name": "/${NAME_PREFIX}/bootstrap",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 14
          },
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/${NAME_PREFIX}/system",
            "log_stream_name": "{instance_id}/messages",
            "retention_in_days": 14
          }
        ]
      }
    }
  }
}
EOF

B64="$(base64 -w0 <"$CFG" 2>/dev/null || base64 <"$CFG" | tr -d '\n')"

echo "Updating CloudWatch Agent on $INSTANCE_ID (rsyslog → /var/log/messages for OOM)…"
# shellcheck disable=SC2016
CMD_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "DroneFeed CW Agent + rsyslog for /var/log/messages" \
  --parameters "{\"commands\":[\"set -euxo pipefail\",\"dnf -y install rsyslog\",\"systemctl enable --now rsyslog\",\"test -f /var/log/messages\",\"echo ${B64} | base64 -d >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json\",\"/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json\",\"sleep 2\",\"systemctl is-active amazon-cloudwatch-agent\",\"ls -la /var/log/messages\"]}" \
  --query 'Command.CommandId' \
  --output text)"

echo "SSM CommandId: $CMD_ID"
echo "Wait ~1–2 min for /dronefeed/system streams, then OOM filter can see kernel lines."
