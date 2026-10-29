output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.app.name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.app.arn
}

output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.app.name
}

output "service_arn" {
  description = "ARN of the ECS service."
  value       = aws_ecs_service.app.id
}

output "task_definition_arn" {
  description = "ARN of the active ECS task definition."
  value       = aws_ecs_task_definition.app.arn
}

output "log_group_name" {
  description = "CloudWatch log group used by the application container."
  value       = aws_cloudwatch_log_group.app.name
}

output "task_security_group_id" {
  description = "Security group attached to Fargate tasks."
  value       = aws_security_group.tasks.id
}

output "task_execution_role_arn" {
  description = "ARN of the ECS task execution role."
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "ARN of the application task role."
  value       = aws_iam_role.task.arn
}
