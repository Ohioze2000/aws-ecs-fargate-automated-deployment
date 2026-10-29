variable "env_prefix" {
  description = "Environment prefix used to name the ECR repository."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}$", var.env_prefix))
    error_message = "Use a lowercase prefix 2-11 characters long, beginning with a letter."
  }
}

variable "force_delete" {
  description = "Allow Terraform to delete the repository even when it contains images. Keep false for normal production use."
  type        = bool
  default     = false
}

variable "untagged_image_expiration_days" {
  description = "Number of days after which untagged images may expire."
  type        = number
  default     = 14

  validation {
    condition     = var.untagged_image_expiration_days >= 1 && floor(var.untagged_image_expiration_days) == var.untagged_image_expiration_days
    error_message = "untagged_image_expiration_days must be a positive whole number."
  }
}

variable "tags" {
  description = "Tags applied to ECR resources."
  type        = map(string)
  default     = {}
}
