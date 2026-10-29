# Amended ECS Fargate Incident Remediation Implementation

This package retains the existing ECS Fargate application, root Terraform infrastructure, networking, ALB, SSL and GitHub Actions files, and replaces the monitoring pipeline with a single ECS-aware incident path.

## Main flow

- ECS CPU, ECS memory, ALB unhealthy-target, application-error, and ephemeral-storage alarms publish to one SNS topic.
- SNS invokes `modules/monitoring/dispatcher.py`, which filters for `ALARM`, creates a deterministic DynamoDB incident, and asynchronously invokes the worker.
- EventBridge target-health events invoke `event_router.py`; it records an IP-target-aware ECS incident and invokes the same worker. It does not assume EC2 InstanceId or ASG lifecycle events.
- `remediation_worker.py` uses a DynamoDB lease/claim, bounded attempts, ECS service/task state, ALB target health, and the public application health endpoint. It sends detection and result messages to Slack.
- The incident ledger is the single durable record; no duplicate notifier subscription is created.

## Signal policy

- `cpu`: ECS target-tracking autoscaling is the action controller; worker verifies service/target/application health without forcing a task restart.
- `memory`, `ephemeral_storage`, `unhealthy_target`: one bounded `UpdateService(forceNewDeployment=true)` request followed by evidence-based verification.
- `application_errors`: observe-only; blind restarts are deliberately avoided because this can be a code defect.
- Unknown signals: observe-only.

A verified recovery requires an ACTIVE ECS service with enough running tasks, no pending tasks, at least `min_healthy_targets` healthy ALB targets and a successful public health endpoint. A task launch alone is not considered success.

## Copy/paste deployment steps

1. Back up the current repository and download/extract this package. Copy the amended files over the matching paths in your repository.
2. Keep `modules/network`, `modules/alb`, `modules/ssl`, application files, Dockerfile and workflow unless you intend to separately amend those components. The ALB output description was corrected for ECS IP targets.
3. In HCP Terraform, set `slack_webhook_url` as a sensitive workspace variable; keep `env_prefix`, `domain_name`, and `aws_region` aligned with GitHub Actions. Do not add a Secrets Manager ARN for the webhook.
4. Ensure the Route 53 public hosted zone for `domain_name` already exists and the GitHub Actions OIDC role has permissions for the full Terraform plan/apply and ECR push.
5. Run `terraform fmt -recursive`, `terraform init`, `terraform validate`, and `python -m unittest discover -s tests -v` before a plan. Review the plan carefully.
6. The Terraform root is already managing the incident table name `${env_prefix}-incident-ledger`; before applying to a workspace with an existing incident table, inspect state and import/migrate existing resources rather than creating a duplicate or deleting the existing table.
7. Verify that the `ECS/ContainerInsights` `EphemeralStorageUtilized` metric and its ClusterName/ServiceName dimensions actually publish in your account. The alarm is non-breaching on missing data; adjust its metric/dimensions/threshold to match measured units before relying on it.
8. Run an initial plan during a maintenance window. This change removes ASG lifecycle resources and replaces Lambda resources; review Terraform state actions and preserve existing DynamoDB incident history. Do not blindly apply destructive state changes.


## ECR module and state migration

- ECR repository and lifecycle-policy ownership is encapsulated in `modules/ecr/`; the root module consumes `module.ecr.repository_url` and exposes stable root outputs for CI/CD.
- Repository defaults: immutable tags, scan-on-push, AES256 encryption, untagged-image expiration after 14 days, and `force_delete = false` by default.
- The root configuration includes `moved` blocks for the prior root addresses `aws_ecr_repository.app` and `aws_ecr_lifecycle_policy.app`. These are intended to preserve existing ECR resources when Terraform applies the module extraction.
- Before applying to a workspace that already manages ECR, inspect `terraform plan` and confirm the plan shows address moves rather than repository destruction/recreation. Do not remove the `moved` blocks until the state migration has been applied to all relevant workspaces. If a workspace has a different state history, migrate it deliberately rather than assuming the same addresses exist.
- The GitHub Actions ECR bootstrap step targets the resources inside `module.ecr`. Targeted apply is only used to bootstrap ECR before the first image push; run the full plan/apply after publishing the image.

## Important operational notes

- `forceNewDeployment` is bounded by the incident claim and `MAX_REMEDIATION_ATTEMPTS`, but it does not fix a persistent code defect. The worker deliberately avoids restarting on application-error alarms.
- The worker has a 900-second Lambda timeout; set `verification_timeout_seconds` below 900.
- Slack delivery is best-effort; Lambda logs and DynamoDB incident fields remain the operational record. Exactly-once delivery to an external webhook cannot be guaranteed.
- The app health URL is composed as `https://${domain_name}${health_check_path}`. Ensure `/health` returns a successful HTTP response without authentication or redirects to a login page.
- This is a reviewed implementation package, not proof of a successful apply in your AWS account. Validate with a plan and a controlled incident test.


## Child-module boundaries in this revision

- `modules/ecr/` owns the ECR repository and lifecycle policy.
- `modules/ecs/` owns the Fargate cluster, task definition, service, task IAM roles, task security group, application log group, and ECS service autoscaling.
- `modules/alb/`, `modules/network/`, `modules/ssl/`, and `modules/dns/` remain separate infrastructure components; the root module wires their inputs and outputs together.
- The legacy `modules/webserver/` EC2 launch-template and Auto Scaling Group module has been removed. The Fargate service uses private subnets and an ALB IP target group.

The root configuration includes `moved` blocks for the existing root-level ECS resources being extracted into `module.ecs`. On an existing workspace, run a plan and verify these are address moves with no unexpected ECS service, task role, security group, log group, or autoscaling replacement. If the workspace's state differs from these source addresses, reconcile state deliberately before applying.
