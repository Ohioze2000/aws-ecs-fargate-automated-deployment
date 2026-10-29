
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
  type = number 
  default = 90 
}

variable "tags" { 
  type = map(string) 
  default = {} 
  }
