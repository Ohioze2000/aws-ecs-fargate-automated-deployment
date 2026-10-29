output "incident_table_name" {
  description = "DynamoDB table storing the durable incident ledger."
  value       = aws_dynamodb_table.incidents.name
}
output "operations_topic_arn" {
  description = "SNS topic receiving CloudWatch alarm transitions."
  value       = aws_sns_topic.operations.arn
}
