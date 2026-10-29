variable "env_prefix" {
  description = "Environment prefix used to name ECS resources."
  type        = string
}

variable "aws_region" {
  description = "AWS region used by the ECS awslogs driver."
  type        = string
}

variable "image_url" {
  description = "Full immutable ECR image URI, including its tag or digest."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the Fargate tasks."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Fargate tasks."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ALB security group permitted to reach the application container."
  type        = string
}

variable "target_group_arn" {
  description = "ALB IP target group ARN attached to the ECS service."
  type        = string
}

variable "container_port" {
  description = "Application container port."
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "Path used by the container health check."
  type        = string
  default     = "/health"
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Desired ECS service task count."
  type        = number
  default     = 2
}

variable "min_count" {
  description = "Minimum ECS service task count for autoscaling."
  type        = number
  default     = 2
}

variable "max_count" {
  description = "Maximum ECS service task count for autoscaling."
  type        = number
  default     = 6
}

variable "target_cpu_percent" {
  description = "Target average ECS service CPU utilization for scaling."
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "Retention period for application container logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to taggable ECS resources."
  type        = map(string)
  default     = {}
}
