variable "aws_region" {
  description = "AWS region for infrastructure deployment."
  type        = string
}
variable "env_prefix" {
  description = "Short lowercase environment prefix used for resource naming."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}$", var.env_prefix))
    error_message = "Use a lowercase prefix 2-11 characters long, beginning with a letter."
  }
}
variable "vpc_cidr_block" {
  type = string
}
variable "az_count" {
  type = number
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Use 2 or 3 Availability Zones."
  }
}
variable "domain_name" {
  description = "Existing Route 53 public hosted-zone name for the application."
  type        = string
}
variable "create_www_record" {
  type    = bool
  default = true
}
variable "container_port" {
  type = number
}
variable "health_check_path" {
  type = string
}
variable "image_tag" {
  description = "Immutable ECR image tag deployed by CI/CD."
  type        = string
}
variable "task_cpu" {
  type = number
}
variable "task_memory" {
  type = number
}
variable "desired_count" {
  type = number
}
variable "min_count" {
  type = number
}
variable "max_count" {
  type = number
}
variable "target_cpu_percent" {
  type = number
}
variable "log_retention_days" {
  type = number
}
variable "ecr_force_delete" {
  type = bool
}
variable "slack_webhook_url" {
  description = "Slack incoming webhook URL supplied as a sensitive HCP Terraform workspace variable."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://", var.slack_webhook_url))
    error_message = "slack_webhook_url must be an HTTPS URL."
  }
}
variable "incident_ttl_days" {
  type = number
}
variable "max_remediation_attempts" {
  type = number
}
variable "verification_timeout_seconds" {
  type = number
}
variable "min_healthy_targets" {
  type = number
}
variable "tags" {
  type    = map(string)
  default = {}
}
