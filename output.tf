output "application_url" { value = "https://${var.domain_name}" }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "ecs_cluster_name" { value = aws_ecs_cluster.app.name }
output "ecs_service_name" { value = aws_ecs_service.app.name }
output "alb_dns_name" { value = module.alb.alb_dns_name }
output "incident_table_name" { value = module.monitoring.incident_table_name }
