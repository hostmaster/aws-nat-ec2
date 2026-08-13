# observability.tf — SNS-based notifications and CloudWatch Log Group
# retention for the module's own Lambdas. The notification resources
# below are gated on local.notifications_enabled (variables.tf) and
# target var.sns_topic_arn directly; the module never provisions its
# own SNS topic. Log group retention is unconditional -- it applies
# regardless of whether notifications are enabled.

# Explicit log groups, created ahead of each Lambda (via depends_on on
# the function resource in failover.tf/spot_fallback.tf) so neither
# Lambda ever falls back to AWS's implicit "Never expire" default by
# auto-creating its own log group on first invoke.
resource "aws_cloudwatch_log_group" "lambda_failover" {
  name              = "/aws/lambda/${var.name_prefix}-nat-failover"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "lambda_spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  name              = "/aws/lambda/${var.name_prefix}-nat-spot-fallback"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# AWS-native, no Lambda/EventBridge involved — covers every reactive
# replacement reason (Spot reclamation, EC2 status-check failure,
# manual termination), not just the proactive Spot-interruption path
# failover.tf already notifies on.
resource "aws_autoscaling_notification" "nat" {
  count = local.notifications_enabled ? 1 : 0

  group_names = [aws_autoscaling_group.nat.name]
  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]
  topic_arn = var.sns_topic_arn
}

# Backstop alarms: at this Lambdas' invocation volume (only ever
# invoked on a real Spot interruption / fallback flip, not per-request
# traffic), a single Error or Throttle is meaningful on its own, not
# noise -- evaluation_periods=1 and treat_missing_data=notBreaching are
# deliberate here, not the generic multi-period recommendation.
resource "aws_cloudwatch_metric_alarm" "lambda_failover_errors" {
  count = local.notifications_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-nat-failover-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Proactive Spot-failover Lambda (${aws_lambda_function.failover.function_name}) reported an error."

  dimensions = {
    FunctionName = aws_lambda_function.failover.function_name
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_failover_throttles" {
  count = local.notifications_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-nat-failover-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Proactive Spot-failover Lambda (${aws_lambda_function.failover.function_name}) was throttled."

  dimensions = {
    FunctionName = aws_lambda_function.failover.function_name
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_spot_fallback_errors" {
  count = local.notifications_enabled && local.spot_fallback_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-nat-spot-fallback-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Spot-exhaustion fallback Lambda (${aws_lambda_function.spot_fallback[0].function_name}) reported an error."

  dimensions = {
    FunctionName = aws_lambda_function.spot_fallback[0].function_name
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_spot_fallback_throttles" {
  count = local.notifications_enabled && local.spot_fallback_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-nat-spot-fallback-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Spot-exhaustion fallback Lambda (${aws_lambda_function.spot_fallback[0].function_name}) was throttled."

  dimensions = {
    FunctionName = aws_lambda_function.spot_fallback[0].function_name
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.tags
}
