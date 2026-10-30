variable "env_prefix" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "load_balancer_dimension" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "app_healthcheck_url" {
  description = "Public application health endpoint used for post-remediation verification."
  type        = string
}
variable "slack_webhook_url" {
  type      = string
  sensitive = true
}
variable "incident_ttl_days" {
  type    = number
  default = 90
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "max_remediation_attempts" {
  type    = number
  default = 2
}
variable "verification_timeout_seconds" {
  type    = number
  default = 420
}
variable "min_healthy_targets" {
  type    = number
  default = 2
}
variable "tags" {
  type    = map(string)
  default = {}
}
