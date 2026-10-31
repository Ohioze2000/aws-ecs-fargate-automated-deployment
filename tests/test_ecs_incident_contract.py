import ast
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MON = ROOT / "modules" / "monitoring"

class ECSIncidentContractTests(unittest.TestCase):
    def test_lambda_sources_parse(self):
        for name in ("dispatcher.py", "event_router.py", "remediation_worker.py"):
            ast.parse((MON / name).read_text(), filename=name)

    def test_legacy_asg_termination_removed_from_pipeline(self):
        source = "\n".join(p.read_text() for p in MON.glob("*.tf"))
        self.assertNotIn("asg_lifecycle_events", source)
        self.assertNotIn("TerminateInstanceInAutoScalingGroup", source)
        self.assertNotIn("cpu_alarm_manager", source)

    def test_expected_signal_policy_exists(self):
        worker = (MON / "remediation_worker.py").read_text()
        for signal in ("cpu", "memory", "ephemeral_storage", "unhealthy_target", "application_errors"):
            self.assertIn(signal, worker)

    def test_cloudwatch_alarm_states_notify_slack_before_worker(self):
        dispatcher = (MON / "dispatcher.py").read_text()
        pipeline = (MON / "production_pipeline.tf").read_text()
        self.assertIn('aws_sns_topic_subscription" "dispatcher', pipeline)
        self.assertIn('SLACK_WEBHOOK_URL   = var.slack_webhook_url', pipeline)
        self.assertIn('{"ALARM", "OK", "INSUFFICIENT_DATA"}', dispatcher)
        self.assertLess(dispatcher.index('_send_slack(_slack_alarm_message'), dispatcher.index('LAMBDA.invoke('))
        self.assertIn('slack_notification_sent', dispatcher)
        self.assertNotIn('aws_cloudwatch_event_rule" "target_health', pipeline)

if __name__ == "__main__":
    unittest.main()
