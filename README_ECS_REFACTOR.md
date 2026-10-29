# AWS ECS Fargate Automated Incident Remediation

This repository deploys the website from `app/` as an immutable ECR image to ECS Fargate behind an Application Load Balancer, Route 53 and ACM. GitHub Actions validates the repository, builds and pushes a commit-tagged image, and applies Terraform through HCP Terraform.

## Incident lifecycle

`CloudWatch alarms -> SNS -> ECS incident dispatcher -> DynamoDB incident ledger -> bounded ECS remediation worker -> ECS/ALB/application verification -> CloudWatch evidence -> Slack`

Unhealthy ALB target state changes enter through EventBridge and the ECS-aware event router, which records the target IP and creates a durable incident before invoking the same worker. The incident ledger uses conditional writes and worker leases to suppress duplicate processing. The worker verifies running ECS capacity, healthy ALB targets, and the public `/health` endpoint. It does not treat task launch alone as success.

## Signal-specific policy

- CPU: ECS target-tracking autoscaling is the control action; the worker verifies recovery.
- Memory and Fargate ephemeral storage: bounded rolling task replacement followed by verification.
- Unhealthy ALB targets: bounded ECS rolling deployment followed by verification.
- Application errors and unknown signals: observe-only to avoid blindly restarting a persistent code defect.

Before applying to an existing HCP Terraform workspace, inspect `terraform plan` and state carefully. The monitoring resources have changed from the previous ASG-based design; preserve existing incident-table history and use state migration/import where required. Review `AMENDED_IMPLEMENTATION_GUIDE.md` for exact rollout steps and the remaining account-specific checks.


### ECR module

The `modules/ecr/` child module owns the immutable ECR repository, scan-on-push configuration, encryption, and untagged-image lifecycle policy. The root module and CI workflow consume the repository through module outputs. Review the ECR `moved` blocks and Terraform plan before applying to an existing workspace.


## Terraform module boundaries

- `modules/ecr/`: immutable image repository, scan-on-push, encryption and lifecycle policy.
- `modules/ecs/`: Fargate cluster, task definition, service, task roles, task security group, container log group and service autoscaling.
- `modules/network/`, `modules/alb/`, `modules/ssl/`, `modules/dns/`: network, load balancing, certificate and DNS responsibilities.
- `modules/monitoring/`: alarm signals, durable incident ledger, dispatcher, event router, bounded remediation worker and Slack feedback.

The legacy EC2/Auto Scaling Group `modules/webserver/` module has been removed. The root module connects child-module inputs and outputs. Review the root `moved` blocks and Terraform plan before applying the resource-address refactor to an existing workspace.
