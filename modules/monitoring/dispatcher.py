"""SNS CloudWatch alarm dispatcher for ECS incidents.

Persists an idempotent incident record before asynchronously invoking the worker.
Only ALARM transitions create work; OK transitions are intentionally ignored.
"""
import hashlib
import json
import logging
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)
REGION = os.environ.get("AWS_REGION", "us-east-1")
DDB = boto3.resource("dynamodb", region_name=REGION)
TABLE = DDB.Table(os.environ["INCIDENT_TABLE_NAME"])
LAMBDA = boto3.client("lambda", region_name=REGION)
WORKER_ARN = os.environ["WORKER_FUNCTION_ARN"]
ENV_PREFIX = os.environ.get("ENV_PREFIX", "unknown")
TTL_DAYS = int(os.environ.get("INCIDENT_TTL_DAYS", "90"))
CLUSTER_NAME = os.environ["CLUSTER_NAME"]
SERVICE_NAME = os.environ["SERVICE_NAME"]
TARGET_GROUP_ARN = os.environ["TARGET_GROUP_ARN"]
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")


def _now():
    return datetime.now(timezone.utc).isoformat()


def _signal(alarm_name):
    name = (alarm_name or "").lower()
    if "incident-dispatcher-errors" in name or "incident-worker-errors" in name or "incident-worker-dlq" in name:
        return None
    if "high-cpu" in name or "cpu" in name:
        return "cpu"
    if "high-memory" in name or "memory" in name:
        return "memory"
    if "ephemeral-storage" in name or "disk" in name or "storage" in name:
        return "ephemeral_storage"
    if "unhealthy-target" in name or "unhealthy-host" in name or "alb" in name or "target-health" in name:
        return "unhealthy_target"
    if "application-error" in name or "app-error" in name:
        return "application_errors"
    return "unknown"


def _dimensions(trigger):
    result = {}
    for metric in (trigger or {}).get("Metrics", []) or []:
        for dimension in (metric.get("MetricStat", {}).get("Metric", {}).get("Dimensions", []) or []):
            result[dimension.get("name")] = dimension.get("value")
    for dimension in (trigger or {}).get("Dimensions", []) or []:
        result[dimension.get("name")] = dimension.get("value")
    return result


def _parse_message(message):
    try:
        parsed = json.loads(message)
    except (TypeError, json.JSONDecodeError):
        return None
    # CloudWatch alarm notifications include AlarmName, AlarmArn, NewStateValue, Trigger.
    if "AlarmName" not in parsed:
        return None
    return parsed


def _send_slack(text):
    """Deliver an alarm-state notification; fail the invocation if Slack rejects it."""
    if not SLACK_WEBHOOK_URL:
        raise RuntimeError("SLACK_WEBHOOK_URL is not configured on the incident dispatcher")
    request = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=json.dumps({"text": text}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            body = response.read().decode("utf-8", errors="replace")
            if not 200 <= response.status < 300 or body.strip().lower() not in ("", "ok"):
                raise RuntimeError(f"Slack webhook returned HTTP {response.status}: {body[:200]}")
    except (urllib.error.URLError, TimeoutError) as exc:
        LOG.exception("Slack alarm notification delivery failed")
        raise RuntimeError("Slack alarm notification delivery failed") from exc


def _slack_alarm_message(alarm, state, signal):
    return (
        f"*AWS CloudWatch Alarm: {state}*\\n"
        f"*Environment:* `{ENV_PREFIX}`\\n"
        f"*Alarm:* `{alarm.get('AlarmName', 'unknown')}`\\n"
        f"*Signal:* `{signal or 'pipeline_health'}`\\n"
        f"*State changed at:* `{alarm.get('StateChangeTime', 'unknown')}`\\n"
        f"*Reason:* {alarm.get('NewStateReason', 'No reason supplied')}\\n"
        f"*Region:* `{REGION}`\\n"
        "CloudWatch alarm-state transition received; this message reports the observed CloudWatch state."
    )


def lambda_handler(event, context):
    accepted = 0
    notified = 0
    for record in event.get("Records", []):
        if record.get("EventSource") != "aws:sns":
            LOG.warning("Ignoring non-SNS record")
            continue
        alarm = _parse_message(record.get("Sns", {}).get("Message", ""))
        if not alarm:
            LOG.warning("Ignoring non-CloudWatch SNS message")
            continue

        state = alarm.get("NewStateValue", "UNKNOWN")
        if state not in {"ALARM", "OK", "INSUFFICIENT_DATA"}:
            LOG.warning("Ignoring unsupported CloudWatch alarm state=%s", state)
            continue

        alarm_arn = alarm.get("AlarmArn", alarm.get("AlarmName", "unknown"))
        state_time = alarm.get("StateChangeTime", _now())
        incident_id = "INC-" + hashlib.sha256(f"{alarm_arn}|{state_time}|{state}".encode()).hexdigest()[:24].upper()
        signal = _signal(alarm.get("AlarmName", ""))

        # CloudWatch state transitions are always announced to Slack, including OK
        # and INSUFFICIENT_DATA. Pipeline-health alarms are notified but never
        # recursively dispatched to the remediation worker.
        item = {
            "incident_id": incident_id, "source": "cloudwatch_alarm_state",
            "environment": ENV_PREFIX, "alarm_name": alarm.get("AlarmName", "unknown"),
            "alarm_arn": alarm_arn, "alarm_state": state, "alarm_state_at": state_time,
            "signal_type": signal or "pipeline_health", "scope": "alarm_state_notification",
            "cluster_name": CLUSTER_NAME, "service_name": SERVICE_NAME,
            "target_group_arn": TARGET_GROUP_ARN, "reason": alarm.get("NewStateReason", "CloudWatch alarm state changed"),
            "status": "ALARM_STATE_RECEIVED", "attempt_count": 0,
            "created_at": _now(), "updated_at": _now(),
            "ttl": int(time.time()) + TTL_DAYS * 86400,
        }
        is_new = False
        try:
            TABLE.put_item(Item=item, ConditionExpression="attribute_not_exists(incident_id)")
            is_new = True
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            LOG.info("Duplicate CloudWatch state event incident_id=%s", incident_id)

        # Send notification before any remediation worker invocation.
        # Retries can repeat the Slack message if delivery succeeded but the
        # subsequent DynamoDB update failed; this is safer than silently losing it.
        if is_new:
            _send_slack(_slack_alarm_message(alarm, state, signal))
            TABLE.update_item(
                Key={"incident_id": incident_id},
                UpdateExpression="SET slack_notification_sent=:yes, updated_at=:now",
                ExpressionAttributeValues={":yes": True, ":now": _now()},
            )
            notified += 1
        else:
            existing = TABLE.get_item(Key={"incident_id": incident_id}, ConsistentRead=True).get("Item", {})
            if not existing.get("slack_notification_sent"):
                _send_slack(_slack_alarm_message(alarm, state, signal))
                TABLE.update_item(
                    Key={"incident_id": incident_id},
                    UpdateExpression="SET slack_notification_sent=:yes, updated_at=:now",
                    ExpressionAttributeValues={":yes": True, ":now": _now()},
                )
                notified += 1

        if state != "ALARM":
            LOG.info("CloudWatch state notification sent; no remediation for state=%s alarm=%s", state, alarm.get("AlarmName"))
            continue
        if signal is None:
            LOG.warning("Pipeline-health alarm notified to Slack; suppressing recursive remediation dispatch alarm=%s", alarm.get("AlarmName"))
            continue

        # Use a separate stable incident ID for the remediation record so state
        # notification bookkeeping cannot be mistaken for a worker incident.
        worker_incident_id = "INC-" + hashlib.sha256(f"{alarm_arn}|{state_time}".encode()).hexdigest()[:24].upper()
        dims = _dimensions(alarm.get("Trigger", {}))
        worker_item = {
            "incident_id": worker_incident_id, "source": "cloudwatch_alarm",
            "environment": ENV_PREFIX, "alarm_name": alarm.get("AlarmName", "unknown"),
            "alarm_arn": alarm_arn, "alarm_state": state, "alarm_state_at": state_time,
            "signal_type": signal, "scope": "ecs_service",
            "cluster_name": dims.get("ClusterName", CLUSTER_NAME),
            "service_name": dims.get("ServiceName", SERVICE_NAME),
            "target_group_arn": TARGET_GROUP_ARN, "dimensions": dims,
            "reason": alarm.get("NewStateReason", "CloudWatch alarm entered ALARM"),
            "status": "DISPATCHED", "attempt_count": 0, "created_at": _now(), "updated_at": _now(),
            "ttl": int(time.time()) + TTL_DAYS * 86400,
        }
        should_dispatch = False
        try:
            TABLE.put_item(Item=worker_item, ConditionExpression="attribute_not_exists(incident_id)")
            should_dispatch = True
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            existing = TABLE.get_item(Key={"incident_id": worker_incident_id}, ConsistentRead=True).get("Item", {})
            if existing.get("status") == "DISPATCH_FAILED":
                should_dispatch = True
                TABLE.update_item(
                    Key={"incident_id": worker_incident_id},
                    UpdateExpression="SET #s=:s, updated_at=:t",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":s": "DISPATCHED", ":t": _now()},
                )
            else:
                LOG.info("Duplicate alarm remediation ignored incident_id=%s status=%s", worker_incident_id, existing.get("status"))
        if should_dispatch:
            try:
                LAMBDA.invoke(
                    FunctionName=WORKER_ARN, InvocationType="Event",
                    Payload=json.dumps({"incident_id": worker_incident_id}).encode(),
                )
            except Exception as exc:
                TABLE.update_item(
                    Key={"incident_id": worker_incident_id},
                    UpdateExpression="SET #s=:s, dispatch_error=:e, updated_at=:t",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":s": "DISPATCH_FAILED", ":e": type(exc).__name__, ":t": _now()},
                )
                raise
            accepted += 1
            LOG.info("Dispatched incident_id=%s signal=%s alarm=%s after Slack alert", worker_incident_id, signal, alarm.get("AlarmName"))
    return {"status": "accepted", "dispatched": accepted, "slack_notifications": notified}
