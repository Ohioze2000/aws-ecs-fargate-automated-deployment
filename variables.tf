
variable "aws_region" {
  type    = string
}

variable "env_prefix" {
  type    = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}$", var.env_prefix))
    error_message = "Use a short lowercase prefix (2-11 characters)."
  }
}

variable "vpc_cidr_block" { 
    type = string 
}

variable "az_count" {
  type    = number
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Use 2 or 3 AZs."
  }
}

variable "domain_name" { 
    type = string 
    description = "Existing Route 53 public hosted-zone domain name." 
}

variable "create_www_record" { 
    type = bool 
    default = true 
}

variable "container_port" { 
    type = number 
    default = 80 
}

variable "health_check_path" { 
    type = string  
}

variable "image_tag" { 
    type = string 
    description = "Immutable ECR tag deployed by CI/CD." 
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
    default = false 
}

variable "slack_webhook_url" {
    type        = string
    sensitive   = true
    description = "Set as a sensitive HCP Terraform workspace variable."
}

variable "incident_ttl_days" { 
    type = number 
}

variable "tags" { 
    type = map(string) 
    default = {} 
  }
