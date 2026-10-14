"""Check EC2 power state after weekday start/stop; publish SNS if unexpected."""
import json
import os

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")


def handler(event, _context):
    instance_id = os.environ["INSTANCE_ID"]
    topic_arn = os.environ["SNS_TOPIC_ARN"]
    name_prefix = os.environ.get("NAME_PREFIX", "dronefeed")
    expect = (event or {}).get("expect", "running")

    resp = ec2.describe_instances(InstanceIds=[instance_id])
    reservations = resp.get("Reservations") or []
    if not reservations or not reservations[0].get("Instances"):
        state = "missing"
        instance_type = "?"
    else:
        inst = reservations[0]["Instances"][0]
        state = inst.get("State", {}).get("Name", "unknown")
        instance_type = inst.get("InstanceType", "?")

    ok = (expect == "running" and state == "running") or (
        expect == "stopped" and state in ("stopped", "stopping")
    )
    if ok:
        return {"ok": True, "state": state, "expect": expect}

    if expect == "running":
        subject = f"[{name_prefix}] Schedule miss: instance not running"
        body = (
            f"DroneFeed weekday start check failed.\n\n"
            f"Expected: running\n"
            f"Actual:   {state}\n"
            f"Instance: {instance_id} ({instance_type})\n\n"
            f"The business-hours start schedule may have missed or the host failed to come up."
        )
    else:
        subject = f"[{name_prefix}] Instance on too long (did not stop)"
        body = (
            f"DroneFeed weekday stop check failed.\n\n"
            f"Expected: stopped\n"
            f"Actual:   {state}\n"
            f"Instance: {instance_id} ({instance_type})\n\n"
            f"The host is still up after the scheduled stop window."
        )

    sns.publish(TopicArn=topic_arn, Subject=subject[:100], Message=body)
    return {"ok": False, "state": state, "expect": expect, "notified": True}
