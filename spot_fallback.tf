# spot_fallback.tf — CloudWatch alarm, fallback Lambda, Lambda IAM role.

data "archive_file" "lambda_spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/scripts/lambda_spot_fallback.py"
  output_path = "${path.module}/.terraform/tmp/lambda_spot_fallback.zip"
}

data "aws_iam_policy_document" "lambda_spot_fallback_assume_role" {
  count = local.spot_fallback_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  name_prefix        = "${var.name_prefix}-nat-spot-fb-"
  assume_role_policy = data.aws_iam_policy_document.lambda_spot_fallback_assume_role[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda_spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  statement {
    sid       = "UpdateNatAsg"
    actions   = ["autoscaling:UpdateAutoScalingGroup"]
    resources = [aws_autoscaling_group.nat.arn]
  }

  statement {
    sid       = "DescribeAsg"
    actions   = ["autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"]
  }

  statement {
    sid = "LambdaLogging"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.name_prefix}-nat-spot-fallback:*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  name_prefix = "${var.name_prefix}-nat-spot-fb-"
  role        = aws_iam_role.lambda_spot_fallback[0].id
  policy      = data.aws_iam_policy_document.lambda_spot_fallback[0].json
}

resource "aws_lambda_function" "spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  function_name    = "${var.name_prefix}-nat-spot-fallback"
  filename         = data.archive_file.lambda_spot_fallback[0].output_path
  source_code_hash = data.archive_file.lambda_spot_fallback[0].output_base64sha256
  handler          = "lambda_spot_fallback.handler"
  runtime          = "python3.13"
  role             = aws_iam_role.lambda_spot_fallback[0].arn
  timeout          = 10

  environment {
    variables = {
      ASG_NAME = aws_autoscaling_group.nat.name
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-nat-spot-fallback"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.spot_fallback_alarm_evaluation_periods
  metric_name         = "GroupInServiceInstances"
  namespace           = "AWS/AutoScaling"
  period              = var.spot_fallback_alarm_period_seconds
  statistic           = "Minimum"
  threshold           = 1
  # Missing != zero InService; only an explicit published value < 1
  # should trigger fallback (avoids false alarms before metrics warm up).
  treat_missing_data = "notBreaching"
  alarm_description  = "NAT ASG has zero InService instances while Spot-only; flip to On-Demand."

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.nat.name
  }

  alarm_actions = [aws_lambda_function.spot_fallback[0].arn]

  tags = var.tags
}

resource "aws_lambda_permission" "allow_cloudwatch_spot_fallback" {
  count = local.spot_fallback_enabled ? 1 : 0

  statement_id  = "AllowCloudWatchAlarmInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spot_fallback[0].function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.spot_fallback[0].arn
}
