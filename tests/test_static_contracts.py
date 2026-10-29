from pathlib import Path
import ast
import unittest

ROOT = Path(__file__).resolve().parents[1]
MON = ROOT / "modules" / "monitoring"

class ECSPlatformContractTests(unittest.TestCase):
    def test_lambda_sources_parse(self):
        for name in ("dispatcher.py", "event_router.py", "remediation_worker.py"):
            ast.parse((MON / name).read_text(), filename=name)

    def test_fargate_and_immutable_ecr(self):
        main = (ROOT / "main.tf").read_text()
        ecs_main = (ROOT / "modules" / "ecs" / "main.tf").read_text()
        ecr_main = (ROOT / "modules" / "ecr" / "main.tf").read_text()
        self.assertIn('source = "./modules/ecs"', main)
        self.assertIn('source = "./modules/ecr"', main)
        self.assertIn('requires_compatibilities = ["FARGATE"]', ecs_main)
        self.assertIn('image_tag_mutability = "IMMUTABLE"', ecr_main)
        self.assertIn('value       = module.ecr.repository_url', (ROOT / "output.tf").read_text())
        self.assertIn('assign_public_ip = false', ecs_main)
        self.assertIn('value = "enhanced"', ecs_main)
        self.assertFalse((ROOT / "modules" / "webserver").exists())

    def test_idempotency_and_ecs_verification_contract(self):
        dispatcher = (MON / "dispatcher.py").read_text()
        router = (MON / "event_router.py").read_text()
        worker = (MON / "remediation_worker.py").read_text()
        self.assertIn("attribute_not_exists(incident_id)", dispatcher)
        self.assertIn("attribute_not_exists(incident_id)", router)
        self.assertIn("describe_target_health", worker)
        self.assertIn("APP_HEALTHCHECK_URL", worker)
        self.assertIn("forceNewDeployment", worker)
        monitoring = (MON / "main.tf").read_text()
        self.assertIn("TaskEphemeralStorageUtilization", monitoring)
        notify_body = worker[worker.index("def _notify(incident, phase, detail):"):worker.index("def _claim(incident_id):")]
        self.assertLess(notify_body.index("_publish_evidence(incident, phase)"), notify_body.index("_slack(msg)"))

    def test_legacy_asg_remediation_removed(self):
        pipeline = (MON / "production_pipeline.tf").read_text()
        worker = (MON / "remediation_worker.py").read_text()
        self.assertNotIn("asg_lifecycle_events", pipeline)
        self.assertNotIn("TerminateInstanceInAutoScalingGroup", pipeline + worker)
        self.assertNotIn("ASG_NAME", worker)

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
