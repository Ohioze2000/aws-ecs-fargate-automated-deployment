"""SNS -> CloudWatch evidence -> idempotent incident ledger -> Slack enrichment."""
import hashlib
import json
import os
import time
import urllib.request
import boto3

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
ECS = boto3.client("ecs")
ELB = boto3.client("elbv2")
CW = boto3.client("cloudwatch")
CLUSTER = os.environ["CLUSTER_NAME"]
SERVICE = os.environ["SERVICE_NAME"]
TG = os.environ["TARGET_GROUP_ARN"]
WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]
TTL_DAYS = int(os.environ.get("TTL_DAYS", "90"))
NAMESPACE = os.environ.get("NAMESPACE", "Application/Operations")


def _publish_evidence(kind, value=1):
    # CloudWatch log entry is emitted by Lambda runtime; this metric is published
    # before Slack delivery, leaving durable operational evidence even if Slack fails.
    CW.put_metric_data(Namespace=NAMESPACE, MetricData=[{
        "MetricName": kind, "Value": value, "Unit": "Count",
        "Dimensions": [{"Name": "ClusterName", "Value": CLUSTER}, {"Name": "ServiceName", "Value": SERVICE}]
    }])


def _enrich():
    services = ECS.describe_services(cluster=CLUSTER, services=[SERVICE]).get("services", [])
    service = services[0] if services else {}
    targets = ELB.describe_target_health(TargetGroupArn=TG).get("TargetHealthDescriptions", [])
    health = [{"target": t.get("Target", {}).get("Id"), "port": t.get("Target", {}).get("Port"),
               "state": t.get("TargetHealth", {}).get("State"), "reason": t.get("TargetHealth", {}).get("Reason")}
              for t in targets]
    return {"running": service.get("runningCount", 0), "desired": service.get("desiredCount", 0),
            "pending": service.get("pendingCount", 0), "deployments": len(service.get("deployments", [])),
            "targets": health}


def _slack(text):
    req = urllib.request.Request(WEBHOOK, data=json.dumps({"text": text}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=8) as response:
        if response.status < 200 or response.status >= 300:
            raise RuntimeError("Slack webhook returned non-success status")


def lambda_handler(event, context):
    results = []
    for record in event.get("Records", []):
        payload = json.loads(record.get("Sns", {}).get("Message", "{}"))
        alarm = payload.get("AlarmName", payload.get("alarm_name", "application-event"))
        state = payload.get("NewStateValue", payload.get("state", "EVENT"))
        event_kind = payload.get("event_type", payload.get("detail-type", ""))
        if event_kind in ("RemediationSuccessful", "Remediation Verification Completed") or payload.get("remediation_status") == "SUCCESS":
            state = "REMEDIATION_SUCCESS"
        at = payload.get("StateChangeTime", payload.get("timestamp", str(int(time.time()))))
        # SNS redelivery for a given alarm transition must not spam Slack.
        incident_id = "INC-" + hashlib.sha256(f"{alarm}|{at}|{state}".encode()).hexdigest()[:24]
        try:
            TABLE.put_item(Item={"incident_id": incident_id, "alarm_name": alarm, "state": state,
                                 "timestamp": at, "status": "OBSERVED", "ttl": int(time.time()) + TTL_DAYS * 86400},
                           ConditionExpression="attribute_not_exists(incident_id)")
        except TABLE.meta.client.exceptions.ConditionalCheckFailedException:
            results.append({"incident_id": incident_id, "status": "duplicate"})
            continue
        # CloudWatch-first: persist an evidence metric before attempting notification.
        _publish_evidence("RemediationSuccessful" if state == "REMEDIATION_SUCCESS" else ("IncidentDetected" if state == "ALARM" else "AlarmStateChanged"))
        detail = _enrich()
        text = (f"*AWS operations event* `{state}`\nAlarm: `{alarm}`\nIncident: `{incident_id}`\n"
                f"Cluster/service: `{CLUSTER}/{SERVICE}`\nTasks: {detail['running']}/{detail['desired']} running "
                f"({detail['pending']} pending); deployments: {detail['deployments']}\n"
                f"ALB targets: `{json.dumps(detail['targets'])}`\nCloudWatch evidence metric published before Slack.")
        _slack(text)
        TABLE.update_item(Key={"incident_id": incident_id},
                          UpdateExpression="SET #s = :s, notified_at = :n",
                          ExpressionAttributeNames={"#s": "status"},
                          ExpressionAttributeValues={":s": "NOTIFIED", ":n": int(time.time())})
        results.append({"incident_id": incident_id, "status": "notified"})
    return {"results": results}
