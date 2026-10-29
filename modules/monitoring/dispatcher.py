"""SNS CloudWatch alarm dispatcher for ECS incidents.

Persists an idempotent incident record before asynchronously invoking the worker.
Only ALARM transitions create work; OK transitions are intentionally ignored.
"""
import hashlib
import json
import logging
import os
import time
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


def lambda_handler(event, context):
    accepted = 0
    for record in event.get("Records", []):
        if record.get("EventSource") != "aws:sns":
            LOG.warning("Ignoring non-SNS record")
            continue
        alarm = _parse_message(record.get("Sns", {}).get("Message", ""))
        if not alarm:
            LOG.warning("Ignoring non-CloudWatch SNS message")
            continue
        if alarm.get("NewStateValue") != "ALARM":
            LOG.info("Ignoring non-ALARM transition alarm=%s state=%s", alarm.get("AlarmName"), alarm.get("NewStateValue"))
            continue
        alarm_arn = alarm.get("AlarmArn", alarm.get("AlarmName", "unknown"))
        state_time = alarm.get("StateChangeTime", _now())
        incident_id = "INC-" + hashlib.sha256(f"{alarm_arn}|{state_time}".encode()).hexdigest()[:24].upper()
        dims = _dimensions(alarm.get("Trigger", {}))
        signal = _signal(alarm.get("AlarmName", ""))
        if signal is None:
            LOG.error("Pipeline-health alarm requires operator attention; suppressing recursive incident dispatch alarm=%s", alarm.get("AlarmName"))
            continue
        if signal == "unhealthy_target":
            LOG.info("ALB target alarms are correlated by the EventBridge target-health route; skipping alarm-only duplicate alarm=%s", alarm.get("AlarmName"))
            continue
        item = {
            "incident_id": incident_id, "source": "cloudwatch_alarm", "environment": ENV_PREFIX,
            "alarm_name": alarm.get("AlarmName", "unknown"), "alarm_arn": alarm_arn,
            "alarm_state": alarm.get("NewStateValue", "ALARM"), "alarm_state_at": state_time,
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
            TABLE.put_item(Item=item, ConditionExpression="attribute_not_exists(incident_id)")
            should_dispatch = True
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            existing = TABLE.get_item(Key={"incident_id": incident_id}, ConsistentRead=True).get("Item", {})
            if existing.get("status") == "DISPATCH_FAILED":
                should_dispatch = True
                TABLE.update_item(Key={"incident_id": incident_id}, UpdateExpression="SET #s=:s, updated_at=:t", ExpressionAttributeNames={"#s":"status"}, ExpressionAttributeValues={":s":"DISPATCHED", ":t":_now()})
            else:
                LOG.info("Duplicate alarm ignored incident_id=%s status=%s", incident_id, existing.get("status"))
        if should_dispatch:
            try:
                LAMBDA.invoke(FunctionName=WORKER_ARN, InvocationType="Event", Payload=json.dumps({"incident_id": incident_id}).encode())
            except Exception as exc:
                TABLE.update_item(Key={"incident_id": incident_id}, UpdateExpression="SET #s=:s, dispatch_error=:e, updated_at=:t", ExpressionAttributeNames={"#s":"status"}, ExpressionAttributeValues={":s":"DISPATCH_FAILED", ":e":type(exc).__name__, ":t":_now()})
                raise
            accepted += 1
            LOG.info("Dispatched incident_id=%s signal=%s alarm=%s", incident_id, signal, alarm.get("AlarmName"))
    return {"status": "accepted", "dispatched": accepted}
