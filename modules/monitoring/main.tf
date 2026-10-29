resource "aws_sns_topic" "alarms" {
  name = "${var.env_prefix}-operations-events"
  tags = var.tags
}
resource "aws_sns_topic_policy" "alarms" {
  arn = aws_sns_topic.alarms.arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid = "CloudWatchPublish", Effect = "Allow",
    Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "sns:Publish",
    Resource = aws_sns_topic.alarms.arn,
    Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
  }] })
}
data "aws_caller_identity" "current" {}
resource "aws_dynamodb_table" "incidents" {
  name = "${var.env_prefix}-incident-ledger"
  billing_mode = "PAY_PER_REQUEST"
  hash_key = "incident_id"
  attribute { 
    name = "incident_id" 
    type = "S" 
    }
  point_in_time_recovery { 
    enabled = true 
    }
  server_side_encryption { 
    enabled = true 
    }
  ttl { 
    attribute_name = "ttl" 
    enabled = true 
    }
  tags = var.tags
}
resource "aws_iam_role" "notifier" {
  name = "${var.env_prefix}-operations-notifier"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags = var.tags
}
resource "aws_iam_role_policy_attachment" "logs" {
  role = aws_iam_role.notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "notifier" {
  name = "${var.env_prefix}-operations-notifier-policy"
  role = aws_iam_role.notifier.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = aws_dynamodb_table.incidents.arn },
    { Effect = "Allow", Action = ["ecs:DescribeServices", "ecs:DescribeTasks", "ecs:ListTasks"], Resource = "*" },
    { Effect = "Allow", Action = ["elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:DescribeTargetGroups"], Resource = "*" },
    { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*" }
  ] })
}
resource "aws_cloudwatch_log_group" "notifier" {
  name = "/aws/lambda/${var.env_prefix}-operations-notifier"
  retention_in_days = 30
  tags = var.tags
}
data "archive_file" "notifier" {
  type = "zip"
  source_file = "${path.module}/notifier.py"
  output_path = "${path.module}/notifier.zip"
}
resource "aws_lambda_function" "notifier" {
  function_name = "${var.env_prefix}-operations-notifier"
  role = aws_iam_role.notifier.arn
  runtime = "python3.12"
  handler = "notifier.lambda_handler"
  filename = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  timeout = 30
  memory_size = 256
  environment { variables = {
    TABLE_NAME = aws_dynamodb_table.incidents.name, SLACK_WEBHOOK_URL = var.slack_webhook_url,
    CLUSTER_NAME = var.cluster_name, SERVICE_NAME = var.service_name, TARGET_GROUP_ARN = var.target_group_arn,
    NAMESPACE = "Application/Operations", TTL_DAYS = tostring(var.incident_ttl_days)
  } }
  depends_on = [aws_cloudwatch_log_group.notifier, aws_iam_role_policy_attachment.logs, aws_iam_role_policy.notifier]
  tags = var.tags
}
resource "aws_lambda_permission" "sns" {
  statement_id = "AllowSNSInvoke"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal = "sns.amazonaws.com"
  source_arn = aws_sns_topic.alarms.arn
}
resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol = "lambda"
  endpoint = aws_lambda_function.notifier.arn
  depends_on = [aws_lambda_permission.sns]
}
resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name = "${var.env_prefix}-ECS-High-CPU"
  namespace = "AWS/ECS"
  metric_name = "CPUUtilization"
  statistic = "Average"
  period = 60
  evaluation_periods = 3
  threshold = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data = "notBreaching"
  dimensions = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions = [aws_sns_topic.alarms.arn]
  tags = var.tags
}
resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name = "${var.env_prefix}-ECS-High-Memory"
  namespace = "AWS/ECS"
  metric_name = "MemoryUtilization"
  statistic = "Average"
  period = 60
  evaluation_periods = 3
  threshold = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data = "notBreaching"
  dimensions = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions = [aws_sns_topic.alarms.arn]
  tags = var.tags
}
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name = "${var.env_prefix}-ALB-Unhealthy-Targets"
  namespace = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic = "Maximum"
  period = 60
  evaluation_periods = 2
  threshold = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data = "notBreaching"
  dimensions = { TargetGroup = element(split(":", var.target_group_arn), 5), LoadBalancer = var.load_balancer_dimension }
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions = [aws_sns_topic.alarms.arn]
  tags = var.tags
}
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name = "${var.env_prefix}-application-errors"
  log_group_name = var.log_group_name
  pattern = "?ERROR ?Error ?Exception ?FATAL"
  metric_transformation { 
    name = "ApplicationErrors" 
    namespace = "Application/Operations" 
    value = "1" 
    default_value = 0 
    }
}
resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name = "${var.env_prefix}-Application-Error-Spike"
  namespace = "Application/Operations"
  metric_name = "ApplicationErrors"
  statistic = "Sum"
  period = 60
  evaluation_periods = 2
  threshold = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data = "notBreaching"
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions = [aws_sns_topic.alarms.arn]
  tags = var.tags
}
# Fargate has no host-level disk metric. Container Insights exposes ephemeral storage
# usage where supported by platform/agent configuration; alarm on the ECS service series.
resource "aws_cloudwatch_metric_alarm" "ephemeral_storage" {
  alarm_name = "${var.env_prefix}-ECS-Ephemeral-Storage"
  namespace = "ECS/ContainerInsights"
  metric_name = "EphemeralStorageUtilized"
  statistic = "Maximum"
  period = 300
  evaluation_periods = 2
  threshold = 18
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data = "notBreaching"
  dimensions = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions = [aws_sns_topic.alarms.arn]
  tags = var.tags
}
