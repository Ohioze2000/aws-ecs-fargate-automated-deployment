# ECS Fargate platform refactor

This repository includes the supplied EstateAgency website under `app/`; it is not a placeholder Python application. The CI workflow builds from the repository-root Dockerfile.

## Application image
The supplied EstateAgency static website is included under `app/`. The root `Dockerfile`
copies those files into Nginx, and `nginx/default.conf` provides `/health` for ECS and
ALB health checks while writing access/error logs to stdout/stderr for CloudWatch.

The supplied theme's contact form is not a functioning backend: its own `app/contactform/Readme.txt`
states that a working PHP/AJAX form is only available in the Pro version. The static page can
render, but form submission needs a separately implemented API/backend before it can be
described as operational.

## Delivery model
`Git push -> GitHub Actions validation -> Docker build -> ECR immutable tag -> Terraform/HCP Terraform -> ECS Fargate -> ALB -> Route 53 + ACM`.

## Operational signal path
`CloudWatch alarm (or operational event) -> SNS -> Python Lambda -> CloudWatch evidence metric + DynamoDB incident ledger -> ECS/ALB enrichment -> Slack`.

The notifier publishes the `IncidentDetected`, `AlarmStateChanged`, or `RemediationSuccessful` metric to CloudWatch before attempting Slack delivery. Lambda logs also land in its CloudWatch log group. A Slack outage therefore does not erase the CloudWatch evidence. DynamoDB provides conditional-write idempotency for alarm transitions and stores the notification status/TTL; it is an incident ledger, not an ECS task scheduler or remediation engine.

## Signals and Fargate considerations
- ECS service CPU and memory utilization.
- ALB unhealthy target count.
- Application error log metric filter.
- Fargate ephemeral storage metric from Container Insights where supported by the selected Fargate platform/Container Insights configuration. Fargate does not expose host-level disk metrics like EC2; validate the exact metric dimensions and availability in the target account before enabling a paging threshold.
- ECS service scheduler replaces failed tasks and deployment circuit-breaker/rollback should be enabled for production hardening. ECS service autoscaling responds to CPU; it is capacity scaling, not a general-purpose incident remediation engine.

## Required HCP Terraform / GitHub configuration
HCP Terraform workspace `DigitalTech/aws-automated-incident-remediation`:
- `slack_webhook_url`: sensitive Terraform variable (never commit a real webhook).
- AWS provider dynamic credentials / workload identity configured for the workspace, or the approved remote execution role.
- `domain_name`: normal Terraform variable; it must identify an existing public Route 53 hosted zone.
- Configure the workspace Terraform version to match `~> 1.16.0`.

GitHub repository/environment:
- Secret `TF_API_TOKEN`.
- Secret `AWS_GITHUB_ROLE_ARN`, scoped to the repository/workflow via GitHub OIDC trust.
- Variables `ECR_REPOSITORY`, `ECS_CLUSTER_NAME`, and `ECS_SERVICE_NAME` for the pipeline's build and post-deploy verification.
- The AWS role must permit ECR push, describe/wait ECS operations, and the required Terraform runner-side AWS calls. Keep Terraform provisioning permissions separate from the ECS task execution/task roles.

## First deployment/bootstrap
The `main`-branch GitHub Actions workflow performs the ECR bootstrap automatically:

1. Validate Terraform formatting/configuration and Python contract tests.
2. Authenticate to AWS using GitHub OIDC.
3. Initialize the HCP Terraform workspace and apply only `aws_ecr_repository.app` plus its lifecycle policy.
4. Log in to ECR. If the immutable `bootstrap` tag does not exist, build the root `Dockerfile` (which packages the supplied `app/` website) and push that initial image. If it already exists, leave it unchanged.
5. Build and push the current commit as `git-<full-commit-SHA>` (unique immutable tag).
6. Run the full Terraform plan/apply with `TF_VAR_image_tag` set to that commit tag, then wait for ECS service stability.

This removes the manual ECR/image prerequisite. The first successful push to `main` creates the ECR repository, publishes the bootstrap and commit-specific images containing the supplied website, and then provisions the ECS service. Pull requests run validation only and do not create AWS resources or publish images.

### Required configuration
- GitHub Environment `production`: secret `AWS_GITHUB_ROLE_ARN` for the OIDC role and secret `TF_API_TOKEN` for HCP Terraform.
- HCP Terraform workspace `DigitalTech/aws-automated-incident-remediation`: configure AWS dynamic credentials/workload identity for Terraform's remote execution, plus `domain_name` and sensitive `slack_webhook_url` variables.
- The GitHub OIDC role needs permission to create/manage the ECR repository and lifecycle policy, push ECR images, and perform the AWS-side operations required by the selected deployment model. Keep this role scoped to this repository and environment.
- Repository variables `ECR_REPOSITORY`, `ECS_CLUSTER_NAME`, and `ECS_SERVICE_NAME` are optional if the Terraform defaults are used (`prod-web-app`, `prod-cluster`, `prod-web-app`). If `env_prefix` changes, set these variables to match the actual resource names.
- Configure the HCP Terraform workspace Terraform version to match `~> 1.16.0`.

**HCP Terraform execution caveat:** Terraform runs in HCP Terraform's remote execution environment do not automatically inherit GitHub's AWS OIDC session. Configure HCP Terraform AWS dynamic credentials/workload identity (recommended) or another approved remote-run credential method independently. The GitHub role is used by workflow steps that call AWS directly, including ECR bootstrap/push and ECS verification.

Do not set `ecr_force_delete=true` for production. Protect the `production` GitHub environment and require review before deployment. The workflow uses a targeted ECR apply only as a bootstrap stage; the subsequent full plan/apply remains the source of truth for the entire stack.

## Scope note
This refactor replaces the active root deployment path with ECS/Fargate resources. Legacy EC2/ASG remediation modules are retained in the repository for reference but are no longer called by root `main.tf`; remove them in a separate reviewed cleanup after validating state migration. Existing Terraform state contains EC2 resources and must not be applied against this new root without a deliberate migration plan and backup.
