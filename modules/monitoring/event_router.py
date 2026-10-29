"""Route unhealthy ALB target events into the ECS incident ledger."""
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
TABLE = boto3.resource("dynamodb", region_name=REGION).Table(os.environ["INCIDENT_TABLE_NAME"])
LAM = boto3.client("lambda", region_name=REGION)
WORKER_ARN = os.environ["WORKER_FUNCTION_ARN"]
ENV_PREFIX = os.environ.get("ENV_PREFIX", "unknown")
TTL_DAYS = int(os.environ.get("INCIDENT_TTL_DAYS", "90"))
CLUSTER_NAME = os.environ["CLUSTER_NAME"]
SERVICE_NAME = os.environ["SERVICE_NAME"]
TARGET_GROUP_ARN = os.environ["TARGET_GROUP_ARN"]


def _now():
    return datetime.now(timezone.utc).isoformat()


def lambda_handler(event, context):
    if event.get("source") != "aws.elasticloadbalancing" or event.get("detail-type") != "ELB Target Health State Change":
        LOG.info("Ignoring unsupported event source=%s type=%s", event.get("source"), event.get("detail-type"))
        return {"status": "ignored"}
    detail = event.get("detail") or {}
    group_arn = detail.get("targetGroupArn")
    health = detail.get("targetHealth") or {}
    state = health.get("state", "unknown")
    if group_arn != TARGET_GROUP_ARN or state not in {"unhealthy", "unused", "unavailable"}:
        return {"status": "ignored", "reason": "target group or state not actionable"}
    target = detail.get("target") or {}
    target_id = str(target.get("id", "unknown"))
    event_time = event.get("time", _now())
    event_id = event.get("id", f"{group_arn}|{target_id}|{event_time}|{state}")
    incident_id = "INC-" + hashlib.sha256(str(event_id).encode()).hexdigest()[:24].upper()
    item = {
        "incident_id": incident_id, "source": "elb_target_health", "environment": ENV_PREFIX,
        "signal_type": "unhealthy_target", "scope": "ecs_service",
        "cluster_name": CLUSTER_NAME, "service_name": SERVICE_NAME,
        "target_group_arn": group_arn, "target_id": target_id,
        "target_port": int(target.get("port", 0) or 0), "target_health_state": state,
        "target_health_reason": health.get("reason", "unknown"),
        "target_health_description": health.get("description", ""),
        "reason": f"ALB target {target_id} entered {state}",
        "event_time": event_time, "event_id": str(event_id), "status": "DISPATCHED",
        "attempt_count": 0, "created_at": _now(), "updated_at": _now(),
        "ttl": int(time.time()) + TTL_DAYS * 86400,
    }
    try:
        TABLE.put_item(Item=item, ConditionExpression="attribute_not_exists(incident_id)")
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            LOG.info("Duplicate target event ignored incident_id=%s", incident_id)
            return {"status": "duplicate", "incident_id": incident_id}
        raise
    try:
        LAM.invoke(FunctionName=WORKER_ARN, InvocationType="Event", Payload=json.dumps({"incident_id": incident_id}).encode())
    except Exception as exc:
        TABLE.update_item(Key={"incident_id": incident_id}, UpdateExpression="SET #s=:s, dispatch_error=:e, updated_at=:t", ExpressionAttributeNames={"#s":"status"}, ExpressionAttributeValues={":s":"DISPATCH_FAILED", ":e":type(exc).__name__, ":t":_now()})
        raise
    LOG.info("Target-health incident dispatched incident_id=%s target_id=%s state=%s", incident_id, target_id, state)
    return {"status": "accepted", "incident_id": incident_id, "target_id": target_id}
