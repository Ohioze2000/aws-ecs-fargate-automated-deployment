
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

variable "slack_webhook_url" {
  type      = string
  sensitive = true
}

variable "incident_ttl_days" {
  type    = number
  default = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "app_healthcheck_url" {
  description = "URL used to verify application health."
  type = string
}

variable "max_remediation_attempts" {
  type    = number
  default = 2
}
variable "verification_timeout_seconds" {
  type    = number
  default = 90
}
variable "min_healthy_targets" {
  type    = number
  default = 2
}

variable "log_retention_in_days" {
  type = number
}

variable "cpu_alarm_threshold" {
  type    = number
  default = 70
}

variable "cpu_alarm_period" {
  type    = number
  default = 60
}

variable "cpu_evaluation_periods" {
  type    = number
  default = 2
}

variable "cpu_datapoints_to_alarm" {

}

variable "asg_name" {

}
