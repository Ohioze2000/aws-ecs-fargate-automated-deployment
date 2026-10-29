terraform {
  required_version = "~> 1.16.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.62" }
    archive = { source = "hashicorp/archive", version = "~> 2.6" }
  }
}
provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}
locals {
  common_tags = merge(var.tags, { Environment = var.env_prefix, ManagedBy = "Terraform", Project = "aws-automated-incident-remediation" })
}
module "network" {
  source = "./modules/network"
  env_prefix = var.env_prefix
  az_count = var.az_count
  vpc_cidr_block = var.vpc_cidr_block
  tags = local.common_tags
}
module "ssl" {
  source = "./modules/ssl"
  env_prefix = var.env_prefix
  domain_name = var.domain_name
  subject_alternative_names = var.create_www_record ? ["www.${var.domain_name}"] : []
  tags = local.common_tags
}
resource "aws_route53_record" "cert_validation" {
  for_each = { for dvo in module.ssl.domain_validation_options : dvo.domain_name => {
    name = dvo.resource_record_name, record = dvo.resource_record_value, type = dvo.resource_record_type
  } }
  allow_overwrite = true
  name = each.value.name
  records = [each.value.record]
  ttl = 60
  type = each.value.type
  zone_id = data.aws_route53_zone.primary.zone_id
}
data "aws_route53_zone" "primary" {
  name = var.domain_name
  private_zone = false
}
resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = module.ssl.certificate_arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
resource "aws_ecr_repository" "app" {
  name = "${var.env_prefix}-web-app"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  force_delete = var.ecr_force_delete
  tags = local.common_tags
}
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({ rules = [{ rulePriority = 1, description = "Expire untagged images after 14 days", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }, action = { type = "expire" } }] })
}
module "alb" {
  source = "./modules/alb"
  env_prefix = var.env_prefix
  vpc_id = module.network.vpc_id
  subnet_ids = module.network.public_subnet_ids
  health_check_path = var.health_check_path
  certificate_arn = aws_acm_certificate_validation.cert.certificate_arn
  tags = local.common_tags
}
resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name = var.domain_name
  type = "A"
  alias { 
    name                   = module.alb.alb_dns_name 
    zone_id                = module.alb.alb_zone_id 
    evaluate_target_health = true 
    }
}
resource "aws_route53_record" "www" {
  count = var.create_www_record ? 1 : 0
  zone_id = data.aws_route53_zone.primary.zone_id
  name = "www.${var.domain_name}"
  type = "A"

  alias { 
    name                   = module.alb.alb_dns_name, 
    zone_id                = module.alb.alb_zone_id, 
    evaluate_target_health = true 
    }
}
resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/${var.env_prefix}/web-app"
  retention_in_days = var.log_retention_days
  tags = local.common_tags
}
resource "aws_ecs_cluster" "app" {
  name = "${var.env_prefix}-cluster"
  setting { 
    name  = "containerInsights" 
    value = "enabled" 
    }
  tags = local.common_tags
}
resource "aws_iam_role" "task_execution" {
  name = "${var.env_prefix}-ecs-task-execution"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags = local.common_tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  role = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name = "${var.env_prefix}-ecs-app-task"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags = local.common_tags
}
resource "aws_security_group" "tasks" {
  name = "${var.env_prefix}-ecs-tasks-sg"
  description = "Only ALB may connect to ECS tasks"
  vpc_id = module.network.vpc_id
  ingress { 
    from_port       = var.container_port 
    to_port         = var.container_port 
    protocol        = "tcp" 
    security_groups = [module.alb.alb_security_group_id] 
    }
  egress { 
    from_port   = 0 
    to_port     = 0, protocol = "-1" 
    cidr_blocks = ["0.0.0.0/0"] 
    }
  tags = local.common_tags
}
resource "aws_ecs_task_definition" "app" {
  family = "${var.env_prefix}-web-app"
  requires_compatibilities = ["FARGATE"]
  network_mode = "awsvpc"
  cpu = tostring(var.task_cpu)
  memory = tostring(var.task_memory)
  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name = "web-app" 
    image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true, portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    logConfiguration = { logDriver = "awslogs", options = {
      "awslogs-group" = aws_cloudwatch_log_group.app.name, "awslogs-region" = var.aws_region, "awslogs-stream-prefix" = "app"
    }},
    healthCheck = { command = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:${var.container_port}${var.health_check_path} || exit 1"], interval = 30, timeout = 5, retries = 3, startPeriod = 30 }
  }])
  tags = local.common_tags
}
resource "aws_ecs_service" "app" {
  name = "${var.env_prefix}-web-app"
  cluster = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count = var.desired_count
  launch_type = "FARGATE"
  platform_version = "LATEST"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent = 200
  health_check_grace_period_seconds = 60
  network_configuration {
    subnets = module.network.private_subnet_ids
    security_groups = [aws_security_group.tasks.id]
    assign_public_ip = false
  }
  load_balancer { 
    target_group_arn = module.alb.target_group_arn 
    container_name = "web-app" 
    container_port = var.container_port 
    }
  depends_on = [module.alb, aws_iam_role_policy_attachment.execution]
  tags = local.common_tags
}
resource "aws_appautoscaling_target" "ecs" {
  max_capacity = var.max_count
  min_capacity = var.min_count
  resource_id = "service/${aws_ecs_cluster.app.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name = "${var.env_prefix}-ecs-cpu-target"
  policy_type = "TargetTrackingScaling"
  resource_id = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value = var.target_cpu_percent
    predefined_metric_specification { 
      predefined_metric_type = "ECSServiceAverageCPUUtilization" 
      }
  }
}
module "monitoring" {
  source = "./modules/monitoring"
  env_prefix = var.env_prefix
  cluster_name = aws_ecs_cluster.app.name
  service_name = aws_ecs_service.app.name
  target_group_arn = module.alb.target_group_arn
  load_balancer_dimension = module.alb.load_balancer_dimension
  log_group_name = aws_cloudwatch_log_group.app.name
  slack_webhook_url = var.slack_webhook_url
  incident_ttl_days = var.incident_ttl_days
  tags = local.common_tags
}
