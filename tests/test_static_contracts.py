"""Offline source-contract checks for the ECS Fargate platform."""
from pathlib import Path
import ast
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ECSPlatformContractTests(unittest.TestCase):
    def test_notifier_parses(self):
        ast.parse((ROOT / "modules/monitoring/notifier.py").read_text())

    def test_fargate_and_immutable_ecr(self):
        main = (ROOT / "main.tf").read_text()
        self.assertIn('requires_compatibilities = ["FARGATE"]', main)
        self.assertIn('image_tag_mutability = "IMMUTABLE"', main)
        self.assertIn('assign_public_ip = false', main)

    def test_cloudwatch_before_slack_and_dynamodb_idempotency(self):
        source = (ROOT / "modules/monitoring/notifier.py").read_text()
        self.assertLess(source.index("_publish_evidence("), source.index("_slack(text)"))
        self.assertIn("attribute_not_exists(incident_id)", source)
        self.assertIn("RemediationSuccessful", source)

    def test_actual_website_and_health_endpoint_are_in_container(self):
        self.assertTrue((ROOT / "app/index.html").exists())
        dockerfile = (ROOT / "Dockerfile").read_text()
        nginx = (ROOT / "nginx/default.conf").read_text()
        self.assertIn("COPY app/", dockerfile)
        self.assertIn("location = /health", nginx)
        self.assertIn('return 200 "ok', nginx)

    def test_workflow_builds_and_deploys(self):
        workflow = (ROOT / ".github/workflows/aws-automated-incident-remediation.yml").read_text()
        self.assertIn("docker build", workflow)
        self.assertIn("docker push", workflow)
        self.assertIn("terraform apply", workflow)
        self.assertIn("services-stable", workflow)

if __name__ == "__main__":
    unittest.main()
