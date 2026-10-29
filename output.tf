output "application_url" {
  description = "Public HTTPS URL for the application."
  value       = "https://${var.domain_name}"
}
output "ecr_repository_url" {
  description = "URL of the Terraform-managed ECR repository."
  value       = module.ecr.repository_url
}

output "ecr_repository_name" {
  description = "Name of the Terraform-managed ECR repository."
  value       = module.ecr.repository_name
}
output "ecs_cluster_name" { value = module.ecs.cluster_name }
output "ecs_service_name" { value = module.ecs.service_name }
output "alb_dns_name" { value = module.alb.alb_dns_name }
output "incident_table_name" { value = module.monitoring.incident_table_name }
output "operations_topic_arn" { value = module.monitoring.operations_topic_arn }
