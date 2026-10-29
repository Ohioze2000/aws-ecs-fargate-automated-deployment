"""Bounded ECS Fargate incident worker with evidence-based verification."""
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
ECS = boto3.client("ecs", region_name=REGION)
ELB = boto3.client("elbv2", region_name=REGION)
CW = boto3.client("cloudwatch", region_name=REGION)
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
CLUSTER_NAME = os.environ["CLUSTER_NAME"]
SERVICE_NAME = os.environ["SERVICE_NAME"]
TARGET_GROUP_ARN = os.environ["TARGET_GROUP_ARN"]
APP_HEALTHCHECK_URL = os.environ["APP_HEALTHCHECK_URL"]
MAX_ATTEMPTS = int(os.environ.get("MAX_REMEDIATION_ATTEMPTS", "2"))
VERIFY_TIMEOUT = int(os.environ.get("VERIFICATION_TIMEOUT_SECONDS", "420"))
MIN_HEALTHY_TARGETS = int(os.environ.get("MIN_HEALTHY_TARGETS", "2"))
TTL_DAYS = int(os.environ.get("INCIDENT_TTL_DAYS", "90"))


def _now():
    return datetime.now(timezone.utc).isoformat()


def _update(incident_id, status, **fields):
    names = {"#status": "status"}
    values = {":status": status, ":now": _now()}
    sets = ["#status = :status", "updated_at = :now"]
    for i, (key, value) in enumerate(fields.items()):
        names[f"#k{i}"] = key
        values[f":v{i}"] = value
        sets.append(f"#k{i} = :v{i}")
    TABLE.update_item(Key={"incident_id": incident_id}, UpdateExpression="SET " + ", ".join(sets), ExpressionAttributeNames=names, ExpressionAttributeValues=values)


def _slack(text):
    if not SLACK_WEBHOOK_URL:
        LOG.warning("SLACK_WEBHOOK_URL is empty; Slack notification skipped")
        return False
    request = urllib.request.Request(SLACK_WEBHOOK_URL, data=json.dumps({"text": text}).encode(), headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            if response.status < 200 or response.status >= 300:
                raise RuntimeError(f"Slack webhook returned HTTP {response.status}")
        return True
    except (urllib.error.URLError, TimeoutError, RuntimeError):
        LOG.exception("Slack notification failed")
        return False


def _publish_evidence(incident, phase):
    metric_by_phase = {
        "DETECTED": "IncidentDetected",
        "RECOVERED": "RemediationSuccessful",
        "OBSERVED": "RemediationObserved",
        "VERIFICATION_FAILED": "RemediationFailed",
        "FAILED": "RemediationFailed",
        "MAX_ATTEMPTS_EXCEEDED": "RemediationFailed",
    }
    metric_name = metric_by_phase.get(phase, "IncidentStatusUpdated")
    CW.put_metric_data(
        Namespace="Application/Operations",
        MetricData=[{
            "MetricName": metric_name,
            "Value": 1,
            "Unit": "Count",
            "Timestamp": datetime.now(timezone.utc),
            "Dimensions": [
                {"Name": "Environment", "Value": str(incident.get("environment", "unknown"))},
                {"Name": "SignalType", "Value": str(incident.get("signal_type", "unknown"))},
            ],
        }],
    )


def _notify(incident, phase, detail):
    # Evidence is emitted first. If CloudWatch evidence publication fails, do not
    # claim the notification sequence succeeded or send Slack ahead of the evidence.
    try:
        _publish_evidence(incident, phase)
    except Exception:
        LOG.exception("CloudWatch incident evidence publication failed; Slack delivery skipped")
        return False
    msg = (
        f"*AWS ECS Incident {phase}*\n"
        f"*Incident:* `{incident.get('incident_id')}`\n"
        f"*Environment:* `{incident.get('environment', 'unknown')}`\n"
        f"*Signal:* `{incident.get('signal_type', 'unknown')}`\n"
        f"*Cluster / service:* `{incident.get('cluster_name', CLUSTER_NAME)}` / `{incident.get('service_name', SERVICE_NAME)}`\n"
        f"*Alarm:* `{incident.get('alarm_name', 'target-health event')}`\n"
        f"*Target:* `{incident.get('target_id', 'service-level')}`\n"
        f"*Reason:* {incident.get('reason', 'No reason supplied')}\n"
        f"*Result:* {detail}"
    )
    return _slack(msg)


def _claim(incident_id):
    now_epoch = int(time.time())
    lease = now_epoch + max(VERIFY_TIMEOUT + 120, 300)
    try:
        response = TABLE.update_item(
            Key={"incident_id": incident_id},
            UpdateExpression="SET #s=:processing, worker_claimed_at=:now, lease_expires_at=:lease, updated_at=:iso ADD attempt_count :one",
            ConditionExpression="#s IN (:dispatched, :dispatch_failed, :retryable) OR (#s=:processing AND lease_expires_at < :epoch)",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":processing": "PROCESSING", ":dispatched": "DISPATCHED", ":dispatch_failed": "DISPATCH_FAILED",
                ":retryable": "RETRYABLE", ":now": now_epoch, ":lease": lease, ":iso": _now(), ":one": 1, ":epoch": now_epoch,
            },
            ReturnValues="ALL_NEW",
        )
        return response["Attributes"]
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            LOG.info("Incident already claimed or terminal incident_id=%s", incident_id)
            return None
        raise


def _service_snapshot(cluster, service):
    response = ECS.describe_services(cluster=cluster, services=[service])
    services = response.get("services", [])
    if not services:
        raise RuntimeError(f"ECS service not found: {cluster}/{service}")
    svc = services[0]
    return {
        "status": svc.get("status"), "desired_count": int(svc.get("desiredCount", 0)),
        "running_count": int(svc.get("runningCount", 0)), "pending_count": int(svc.get("pendingCount", 0)),
        "deployments": [{"status": d.get("status"), "rollout_state": d.get("rolloutState"), "running_count": d.get("runningCount", 0), "desired_count": d.get("desiredCount", 0)} for d in svc.get("deployments", [])],
        "events": [e.get("message", "") for e in svc.get("events", [])[:5]],
    }

def _target_snapshot(target_group_arn):
    if not target_group_arn:
        return {"healthy_count": 0, "unhealthy_count": 0, "targets": []}
    response = ELB.describe_target_health(TargetGroupArn=target_group_arn)
    targets = []
    healthy = 0
    unhealthy = 0
    for item in response.get("TargetHealthDescriptions", []):
        state = item.get("TargetHealth", {}).get("State", "unknown")
        healthy += state == "healthy"
        unhealthy += state in {"unhealthy", "unused", "unavailable"}
        targets.append({"id": item.get("Target", {}).get("Id"), "port": item.get("Target", {}).get("Port"), "state": state, "reason": item.get("TargetHealth", {}).get("Reason", "")})
    return {"healthy_count": int(healthy), "unhealthy_count": int(unhealthy), "targets": targets}

def _endpoint_snapshot():
    request = urllib.request.Request(APP_HEALTHCHECK_URL, headers={"User-Agent": "ecs-incident-verifier/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            return {"ok": 200 <= response.status < 300, "status_code": response.status}
    except Exception as exc:
        return {"ok": False, "error": type(exc).__name__}

def _alarm_state(alarm_name):
    if not alarm_name:
        return "UNKNOWN"
    response = CW.describe_alarms(AlarmNames=[alarm_name])
    alarms = response.get("MetricAlarms", [])
    return alarms[0].get("StateValue", "UNKNOWN") if alarms else "NOT_FOUND"

def _verify(incident, require_alarm_clear=True):
    deadline = time.monotonic() + VERIFY_TIMEOUT
    last = {}
    cluster = incident.get("cluster_name", CLUSTER_NAME)
    service = incident.get("service_name", SERVICE_NAME)
    target_group = incident.get("target_group_arn", TARGET_GROUP_ARN)
    while time.monotonic() < deadline:
        service_data = _service_snapshot(cluster, service)
        target_data = _target_snapshot(target_group)
        endpoint_data = _endpoint_snapshot()
        alarm_state = _alarm_state(incident.get("alarm_name"))
        last = {"service": service_data, "target_health": target_data, "application_endpoint": endpoint_data, "alarm_state": alarm_state}
        alarm_ok = (not require_alarm_clear) or alarm_state != "ALARM"
        deployment_ok = all(d.get("rollout_state") != "FAILED" for d in service_data["deployments"])
        capacity_ok = service_data["status"] == "ACTIVE" and service_data["running_count"] >= min(service_data["desired_count"], MIN_HEALTHY_TARGETS) and service_data["pending_count"] == 0
        targets_ok = target_data["healthy_count"] >= MIN_HEALTHY_TARGETS and target_data["unhealthy_count"] == 0
        if capacity_ok and targets_ok and endpoint_data.get("ok") and deployment_ok and alarm_ok:
            last["verified_at"] = _now()
            return True, last
        time.sleep(15)
    last["verification_timed_out"] = True
    last["verified_at"] = _now()
    return False, last

def _action(incident):
    signal = incident.get("signal_type", "unknown")
    cluster = incident.get("cluster_name", CLUSTER_NAME)
    service = incident.get("service_name", SERVICE_NAME)
    # Safe signal-specific policy: CPU is handled by ECS target-tracking autoscaling;
    # application errors are not blindly restarted because they may be a code defect.
    # Memory, ephemeral-storage and unhealthy-target incidents get one bounded rolling
    # replacement of tasks; the service scheduler maintains desired count throughout.
    if signal == "cpu":
        return "VERIFY_AUTOSCALING", "ECS target-tracking autoscaling is the CPU remediation controller; no forced restart issued."
    if signal == "application_errors":
        return "OBSERVE_ONLY", "Application errors require log/root-cause inspection; no blind restart was issued."
    if signal not in {"memory", "ephemeral_storage", "unhealthy_target"}:
        return "OBSERVE_ONLY", f"Unknown or unsupported signal '{signal}'; no infrastructure action issued."
    ECS.update_service(cluster=cluster, service=service, forceNewDeployment=True)
    return "FORCE_NEW_DEPLOYMENT", "Requested one rolling ECS service deployment to replace tasks; outcome remains pending verification."

def lambda_handler(event, context):
    incident_id = event.get("incident_id") if isinstance(event, dict) else None
    if not incident_id:
        raise ValueError("Worker requires incident_id")
    record = TABLE.get_item(Key={"incident_id": incident_id}, ConsistentRead=True).get("Item")
    if not record:
        raise ValueError(f"Incident record not found: {incident_id}")
    terminal_statuses = {"RECOVERED", "OBSERVED", "VERIFICATION_FAILED", "MAX_ATTEMPTS_EXCEEDED"}
    if record.get("status") in terminal_statuses:
        LOG.info("Terminal incident duplicate ignored incident_id=%s status=%s", incident_id, record.get("status"))
        return {"status": "already_terminal", "incident_id": incident_id, "terminal_status": record.get("status")}
    if int(record.get("attempt_count", 0)) >= MAX_ATTEMPTS:
        _update(incident_id, "MAX_ATTEMPTS_EXCEEDED", failure_reason="Maximum remediation attempts already reached")
        _notify(record, "FAILED", "Maximum bounded remediation attempts already reached; manual investigation required.")
        return {"status": "max_attempts_exceeded", "incident_id": incident_id}
    incident = _claim(incident_id)
    if not incident:
        return {"status": "duplicate_or_already_processing", "incident_id": incident_id}
    try:
        # Detection is sent before the action, and final status is sent after evidence collection.
        detection_sent = _notify(incident, "DETECTED", "Incident accepted; bounded response and verification are starting.")
        action, action_detail = _action(incident)
        _update(incident_id, "VERIFYING", action=action, action_detail=action_detail, detection_notification_sent=detection_sent)
        verified, evidence = _verify(incident, require_alarm_clear=(action != "OBSERVE_ONLY"))
        if action == "OBSERVE_ONLY":
            status = "OBSERVED"
            final_detail = f"Observe-only policy. {action_detail} Verification evidence: {json.dumps(evidence, default=str)[:2500]}"
        elif verified:
            status = "RECOVERED"
            final_detail = f"Recovery verified against ECS service capacity, ALB target health, and application endpoint. Action: {action}. Evidence: {json.dumps(evidence, default=str)[:2500]}"
        else:
            status = "VERIFICATION_FAILED"
            final_detail = f"Recovery could not be verified before timeout. Action: {action}. Evidence: {json.dumps(evidence, default=str)[:2500]}"
        _update(incident_id, status, action=action, action_detail=action_detail, verification_evidence=evidence, verified=bool(verified and action != "OBSERVE_ONLY"), completed_at=_now(), result_notification_sent=False)
        result_sent = _notify(incident, status, final_detail)
        _update(incident_id, status, result_notification_sent=result_sent)
        return {"status": status, "incident_id": incident_id, "action": action, "verified": verified, "evidence": evidence}
    except Exception as exc:
        LOG.exception("Incident processing failed incident_id=%s", incident_id)
        _update(incident_id, "RETRYABLE", failure_reason=type(exc).__name__, error_message=str(exc)[:1000])
        _notify(incident, "FAILED", f"Processing failed with {type(exc).__name__}; inspect the incident ledger and CloudWatch logs.")
        raise
