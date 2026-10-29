resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${var.env_prefix}-ECS-High-CPU"
  alarm_description   = "ECS service CPU is elevated. ECS target tracking handles horizontal scaling; the incident worker verifies recovery."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions       = [aws_sns_topic.operations.arn]
  ok_actions          = [aws_sns_topic.operations.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${var.env_prefix}-ECS-High-Memory"
  alarm_description   = "ECS service memory utilization is elevated; the incident worker performs bounded task replacement and verifies service health."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions       = [aws_sns_topic.operations.arn]
  ok_actions          = [aws_sns_topic.operations.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.env_prefix}-ALB-Unhealthy-Targets"
  alarm_description   = "The ECS service target group has one or more unhealthy targets."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { TargetGroup = element(split(":", var.target_group_arn), 5), LoadBalancer = var.load_balancer_dimension }
  alarm_actions       = [aws_sns_topic.operations.arn]
  ok_actions          = [aws_sns_topic.operations.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${var.env_prefix}-application-errors"
  log_group_name = var.log_group_name
  pattern        = "?ERROR ?Error ?Exception ?FATAL"
  metric_transformation {
    name          = "ApplicationErrors"
    namespace     = "Application/Operations"
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${var.env_prefix}-Application-Error-Spike"
  alarm_description   = "Application error log events exceeded the configured threshold."
  namespace           = "Application/Operations"
  metric_name         = "ApplicationErrors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operations.arn]
  ok_actions          = [aws_sns_topic.operations.arn]
  tags                = var.tags
}

# TaskEphemeralStorageUtilization is a percentage metric from ECS Container Insights
# enhanced observability. It is available for supported Fargate Linux platform versions;
# validate the metric appears in the account before relying on the alarm.
resource "aws_cloudwatch_metric_alarm" "ephemeral_storage" {
  alarm_name          = "${var.env_prefix}-ECS-Ephemeral-Storage"
  alarm_description   = "Fargate task ephemeral storage utilization is elevated, where the metric is available."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "TaskEphemeralStorageUtilization"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions       = [aws_sns_topic.operations.arn]
  ok_actions          = [aws_sns_topic.operations.arn]
  tags                = var.tags
}
