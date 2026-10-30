data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "operations" {
  name = "${var.env_prefix}-operations-events"
  tags = var.tags
}
resource "aws_sns_topic_policy" "operations" {
  arn = aws_sns_topic.operations.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchPublishFromThisAccount"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.operations.arn
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_dynamodb_table" "incidents" {
  name         = "${var.env_prefix}-incident-ledger"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"
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
    enabled        = true
  }
  tags = var.tags
}

resource "aws_sqs_queue" "worker_dlq" {
  name                      = "${var.env_prefix}-incident-worker-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "eventbridge_dlq" {
  name                      = "${var.env_prefix}-target-router-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}
resource "aws_sqs_queue_policy" "eventbridge_dlq" {
  queue_url = aws_sqs_queue.eventbridge_dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.eventbridge_dlq.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.target_health.arn } }
    }]
  })
}

resource "aws_iam_role" "dispatcher" {
  name               = "${var.env_prefix}-incident-dispatcher-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = var.tags
}
resource "aws_iam_role_policy_attachment" "dispatcher_logs" {
  role       = aws_iam_role.dispatcher.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "dispatcher" {
  name = "${var.env_prefix}-incident-dispatcher-policy"
  role = aws_iam_role.dispatcher.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"], Resource = aws_dynamodb_table.incidents.arn },
    { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = aws_lambda_function.worker.arn }
  ] })
}
resource "aws_cloudwatch_log_group" "dispatcher" {
  name              = "/aws/lambda/${var.env_prefix}-incident-dispatcher"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
data "archive_file" "dispatcher" {
  type        = "zip"
  source_file = "${path.module}/dispatcher.py"
  output_path = "${path.module}/dispatcher.zip"
}
resource "aws_lambda_function" "dispatcher" {
  function_name    = "${var.env_prefix}-incident-dispatcher"
  role             = aws_iam_role.dispatcher.arn
  runtime          = "python3.12"
  handler          = "dispatcher.lambda_handler"
  filename         = data.archive_file.dispatcher.output_path
  source_code_hash = data.archive_file.dispatcher.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment { variables = {
    INCIDENT_TABLE_NAME = aws_dynamodb_table.incidents.name
    WORKER_FUNCTION_ARN = aws_lambda_function.worker.arn
    ENV_PREFIX          = var.env_prefix
    INCIDENT_TTL_DAYS   = tostring(var.incident_ttl_days)
    CLUSTER_NAME        = var.cluster_name
    SERVICE_NAME        = var.service_name
    TARGET_GROUP_ARN    = var.target_group_arn
  } }
  depends_on = [aws_cloudwatch_log_group.dispatcher, aws_iam_role_policy_attachment.dispatcher_logs, aws_iam_role_policy.dispatcher]
  tags       = var.tags
}
resource "aws_lambda_permission" "sns_dispatcher" {
  statement_id  = "AllowOperationsSNSInvokeDispatcher"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatcher.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.operations.arn
}
resource "aws_sns_topic_subscription" "dispatcher" {
  topic_arn  = aws_sns_topic.operations.arn
  protocol   = "lambda"
  endpoint   = aws_lambda_function.dispatcher.arn
  depends_on = [aws_lambda_permission.sns_dispatcher]
}

resource "aws_iam_role" "worker" {
  name               = "${var.env_prefix}-incident-worker-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = var.tags
}
resource "aws_iam_role_policy_attachment" "worker_logs" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "worker" {
  name = "${var.env_prefix}-incident-worker-policy"
  role = aws_iam_role.worker.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = aws_dynamodb_table.incidents.arn },
    { Effect = "Allow", Action = ["ecs:DescribeServices", "ecs:UpdateService"], Resource = "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:service/${var.cluster_name}/${var.service_name}" },
    { Effect = "Allow", Action = ["elasticloadbalancing:DescribeTargetHealth"], Resource = var.target_group_arn },
    { Effect = "Allow", Action = ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmsForMetric"], Resource = "*" },
    { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "Application/Operations" } } }
  ] })
}
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${var.env_prefix}-incident-worker"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
data "archive_file" "worker" {
  type        = "zip"
  source_file = "${path.module}/remediation_worker.py"
  output_path = "${path.module}/remediation_worker.zip"
}
resource "aws_lambda_function" "worker" {
  function_name                  = "${var.env_prefix}-incident-worker"
  role                           = aws_iam_role.worker.arn
  runtime                        = "python3.12"
  handler                        = "remediation_worker.lambda_handler"
  filename                       = data.archive_file.worker.output_path
  source_code_hash               = data.archive_file.worker.output_base64sha256
  timeout                        = 900
  memory_size                    = 512
  
  environment { variables = {
    INCIDENT_TABLE_NAME          = aws_dynamodb_table.incidents.name
    SLACK_WEBHOOK_URL            = var.slack_webhook_url
    CLUSTER_NAME                 = var.cluster_name
    SERVICE_NAME                 = var.service_name
    TARGET_GROUP_ARN             = var.target_group_arn
    APP_HEALTHCHECK_URL          = var.app_healthcheck_url
    MAX_REMEDIATION_ATTEMPTS     = tostring(var.max_remediation_attempts)
    VERIFICATION_TIMEOUT_SECONDS = tostring(var.verification_timeout_seconds)
    MIN_HEALTHY_TARGETS          = tostring(var.min_healthy_targets)
    INCIDENT_TTL_DAYS            = tostring(var.incident_ttl_days)
  } }
  depends_on = [aws_cloudwatch_log_group.worker, aws_iam_role_policy_attachment.worker_logs, aws_iam_role_policy.worker]
  tags       = var.tags
}
resource "aws_lambda_function_event_invoke_config" "worker" {
  function_name                = aws_lambda_function.worker.function_name
  maximum_event_age_in_seconds = 3600
  maximum_retry_attempts       = 1
  destination_config {
    on_failure { destination = aws_sqs_queue.worker_dlq.arn }
  }
}
resource "aws_sqs_queue_policy" "worker_dlq" {
  queue_url = aws_sqs_queue.worker_dlq.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sqs:SendMessage", Resource = aws_sqs_queue.worker_dlq.arn,
    Condition = { ArnEquals = { "aws:SourceArn" = aws_lambda_function.worker.arn } }
  }] })
}

resource "aws_iam_role" "router" {
  name               = "${var.env_prefix}-incident-event-router-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = var.tags
}
resource "aws_iam_role_policy_attachment" "router_logs" {
  role       = aws_iam_role.router.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "router" {
  name = "${var.env_prefix}-incident-router-policy"
  role = aws_iam_role.router.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"], Resource = aws_dynamodb_table.incidents.arn },
    { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = aws_lambda_function.worker.arn }
  ] })
}
resource "aws_cloudwatch_log_group" "router" {
  name              = "/aws/lambda/${var.env_prefix}-incident-event-router"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
data "archive_file" "router" {
  type        = "zip"
  source_file = "${path.module}/event_router.py"
  output_path = "${path.module}/event_router.zip"
}
resource "aws_lambda_function" "router" {
  function_name    = "${var.env_prefix}-incident-event-router"
  role             = aws_iam_role.router.arn
  runtime          = "python3.12"
  handler          = "event_router.lambda_handler"
  filename         = data.archive_file.router.output_path
  source_code_hash = data.archive_file.router.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment { variables = {
    INCIDENT_TABLE_NAME = aws_dynamodb_table.incidents.name
    WORKER_FUNCTION_ARN = aws_lambda_function.worker.arn
    ENV_PREFIX          = var.env_prefix
    INCIDENT_TTL_DAYS   = tostring(var.incident_ttl_days)
    CLUSTER_NAME        = var.cluster_name
    SERVICE_NAME        = var.service_name
    TARGET_GROUP_ARN    = var.target_group_arn
  } }
  depends_on = [aws_cloudwatch_log_group.router, aws_iam_role_policy_attachment.router_logs, aws_iam_role_policy.router]
  tags       = var.tags
}
resource "aws_cloudwatch_event_rule" "target_health" {
  name        = "${var.env_prefix}-ecs-target-health-events"
  description = "Route unhealthy ALB target state changes for the ECS Fargate service."
  event_pattern = jsonencode({
    source        = ["aws.elasticloadbalancing"]
    "detail-type" = ["ELB Target Health State Change"]
    detail = {
      targetGroupArn = [var.target_group_arn]
      targetHealth   = { state = ["unhealthy", "unused", "unavailable"] }
    }
  })
  tags = var.tags
}
resource "aws_cloudwatch_event_target" "target_health" {
  rule      = aws_cloudwatch_event_rule.target_health.name
  target_id = "ecs-target-health-router"
  arn       = aws_lambda_function.router.arn
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }
  dead_letter_config { arn = aws_sqs_queue.eventbridge_dlq.arn }
  depends_on = [aws_sqs_queue_policy.eventbridge_dlq]
}
resource "aws_lambda_permission" "eventbridge_router" {
  statement_id  = "AllowEventBridgeTargetHealthRouter"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.target_health.arn
}

resource "aws_cloudwatch_metric_alarm" "dispatcher_errors" {
  alarm_name          = "${var.env_prefix}-Incident-Dispatcher-Errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.dispatcher.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operations.arn]
  tags                = var.tags
}
resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  alarm_name          = "${var.env_prefix}-Incident-Worker-Errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.worker.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operations.arn]
  tags                = var.tags
}
resource "aws_cloudwatch_metric_alarm" "worker_dlq_visible" {
  alarm_name          = "${var.env_prefix}-Incident-Worker-DLQ-Not-Empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.worker_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operations.arn]
  tags                = var.tags
}
