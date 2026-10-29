terraform {
  required_version = "~> 1.15"
  required_providers {
    aws     = { 
      source = "hashicorp/aws" 
      version = "~> 5.62" 
      }
    archive = { 
      source = "hashicorp/archive" 
      version = "~> 2.6" 
      }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { 
    tags = local.common_tags 
    }
}

locals {
  common_tags         = merge(var.tags, { Environment = var.env_prefix, ManagedBy = "Terraform", Project = "aws-automated-incident-remediation" })
  app_healthcheck_url = "https://${var.domain_name}${var.health_check_path}"
}

module "network" {
  source         = "./modules/network"
  env_prefix     = var.env_prefix
  az_count       = var.az_count
  vpc_cidr_block = var.vpc_cidr_block
  tags           = local.common_tags
}

module "ssl" {
  source                    = "./modules/ssl"
  env_prefix                = var.env_prefix
  domain_name               = var.domain_name
  subject_alternative_names = var.create_www_record ? ["www.${var.domain_name}"] : []
  tags                      = local.common_tags
}

data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in module.ssl.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.primary.zone_id
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = module.ssl.certificate_arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

module "ecr" {
  source = "./modules/ecr"

  env_prefix                     = var.env_prefix
  force_delete                   = var.ecr_force_delete
  untagged_image_expiration_days = 14
  tags                           = local.common_tags
}

# Preserve the identity of ECR resources when extracting them from the root module.
# Review the plan to confirm Terraform moves these resources rather than recreating them.
moved {
  from = aws_ecr_repository.app
  to   = module.ecr.aws_ecr_repository.app
}

moved {
  from = aws_ecr_lifecycle_policy.app
  to   = module.ecr.aws_ecr_lifecycle_policy.app
}

# Preserve Terraform state addresses when extracting the existing ECS resources
# from the root module into modules/ecs. Review terraform plan before applying.
moved {
  from = aws_cloudwatch_log_group.app
  to   = module.ecs.aws_cloudwatch_log_group.app
}

moved {
  from = aws_ecs_cluster.app
  to   = module.ecs.aws_ecs_cluster.app
}

moved {
  from = aws_iam_role.task_execution
  to   = module.ecs.aws_iam_role.task_execution
}

moved {
  from = aws_iam_role_policy_attachment.execution
  to   = module.ecs.aws_iam_role_policy_attachment.execution
}

moved {
  from = aws_iam_role.task
  to   = module.ecs.aws_iam_role.task
}

moved {
  from = aws_security_group.tasks
  to   = module.ecs.aws_security_group.tasks
}

moved {
  from = aws_ecs_task_definition.app
  to   = module.ecs.aws_ecs_task_definition.app
}

moved {
  from = aws_ecs_service.app
  to   = module.ecs.aws_ecs_service.app
}

moved {
  from = aws_appautoscaling_target.ecs
  to   = module.ecs.aws_appautoscaling_target.ecs
}

moved {
  from = aws_appautoscaling_policy.cpu
  to   = module.ecs.aws_appautoscaling_policy.cpu
}

module "alb" {
  source            = "./modules/alb"
  env_prefix        = var.env_prefix
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.public_subnet_ids
  health_check_path = var.health_check_path
  certificate_arn   = aws_acm_certificate_validation.cert.certificate_arn
  tags              = local.common_tags
}

resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www" {
  count   = var.create_www_record ? 1 : 0
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

# ECS/Fargate implementation is isolated in its own child module.
module "ecs" {
  source = "./modules/ecs"

  env_prefix            = var.env_prefix
  aws_region            = var.aws_region
  image_url             = "${module.ecr.repository_url}:${var.image_tag}"
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.alb.alb_security_group_id
  target_group_arn      = module.alb.target_group_arn
  container_port        = var.container_port
  health_check_path     = var.health_check_path
  task_cpu              = var.task_cpu
  task_memory           = var.task_memory
  desired_count         = var.desired_count
  min_count             = var.min_count
  max_count             = var.max_count
  target_cpu_percent    = var.target_cpu_percent
  log_retention_days    = var.log_retention_days
  tags                  = local.common_tags
}

module "monitoring" {
  source                       = "./modules/monitoring"
  env_prefix                   = var.env_prefix
  cluster_name                 = module.ecs.cluster_name
  service_name                 = module.ecs.service_name
  target_group_arn             = module.alb.target_group_arn
  load_balancer_dimension      = module.alb.load_balancer_dimension
  log_group_name               = module.ecs.log_group_name
  app_healthcheck_url          = local.app_healthcheck_url
  slack_webhook_url            = var.slack_webhook_url
  incident_ttl_days            = var.incident_ttl_days
  log_retention_days           = var.log_retention_days
  max_remediation_attempts     = var.max_remediation_attempts
  verification_timeout_seconds = var.verification_timeout_seconds
  min_healthy_targets          = var.min_healthy_targets
  tags                         = local.common_tags
}
