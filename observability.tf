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
#
# One map entry per {Lambda, metric} pair rather than four near-
# identical resource blocks. The spot_fallback_* entries are omitted
# entirely (not just count=0) when that Lambda doesn't exist, since
# aws_lambda_function.spot_fallback[0] isn't a valid reference then.
locals {
  lambda_backstop_alarms = merge(
    {
      for metric_name in ["Errors", "Throttles"] :
      "failover_${lower(metric_name)}" => {
        name_suffix   = "nat-failover-${lower(metric_name)}"
        metric_name   = metric_name
        function_name = aws_lambda_function.failover.function_name
        description   = "Proactive Spot-failover Lambda (${aws_lambda_function.failover.function_name}) ${metric_name == "Errors" ? "reported an error" : "was throttled"}."
      }
    },
    local.spot_fallback_enabled ? {
      for metric_name in ["Errors", "Throttles"] :
      "spot_fallback_${lower(metric_name)}" => {
        name_suffix   = "nat-spot-fallback-${lower(metric_name)}"
        metric_name   = metric_name
        function_name = aws_lambda_function.spot_fallback[0].function_name
        description   = "Spot-exhaustion fallback Lambda (${aws_lambda_function.spot_fallback[0].function_name}) ${metric_name == "Errors" ? "reported an error" : "was throttled"}."
      }
    } : {}
  )
}

resource "aws_cloudwatch_metric_alarm" "lambda_backstop" {
  for_each = local.notifications_enabled ? local.lambda_backstop_alarms : {}

  alarm_name          = "${var.name_prefix}-${each.value.name_suffix}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = each.value.metric_name
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = each.value.description

  dimensions = {
    FunctionName = each.value.function_name
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.tags
}

# Preserves existing state addresses across the count -> for_each
# refactor above, so an already-applied module doesn't destroy/recreate
# these alarms on the next apply.
moved {
  from = aws_cloudwatch_metric_alarm.lambda_failover_errors[0]
  to   = aws_cloudwatch_metric_alarm.lambda_backstop["failover_errors"]
}

moved {
  from = aws_cloudwatch_metric_alarm.lambda_failover_throttles[0]
  to   = aws_cloudwatch_metric_alarm.lambda_backstop["failover_throttles"]
}

moved {
  from = aws_cloudwatch_metric_alarm.lambda_spot_fallback_errors[0]
  to   = aws_cloudwatch_metric_alarm.lambda_backstop["spot_fallback_errors"]
}

moved {
  from = aws_cloudwatch_metric_alarm.lambda_spot_fallback_throttles[0]
  to   = aws_cloudwatch_metric_alarm.lambda_backstop["spot_fallback_throttles"]
}
