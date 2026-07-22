# failover.tf — EventBridge rule, Lambda, Lambda IAM role.

data "archive_file" "lambda_failover" {
  type        = "zip"
  source_file = "${path.module}/scripts/lambda_failover.py"
  output_path = "${path.module}/.terraform/tmp/lambda_failover.zip"
}

data "aws_iam_policy_document" "lambda_failover_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_failover" {
  name_prefix        = "${var.name_prefix}-nat-failover-"
  assume_role_policy = data.aws_iam_policy_document.lambda_failover_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda_failover" {
  # Scoped exactly to this module's own ASG — known at plan time,
  # unlike the NAT instance's own self-permissions (iam.tf) which can't
  # know a future instance ID ahead of an ASG launch.
  statement {
    sid       = "TerminateNatInstance"
    actions   = ["autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = [aws_autoscaling_group.nat.arn]
  }

  # List-access-level action with no resource-level permissions defined
  # for it — "*" is the only valid value.
  statement {
    sid       = "DescribeAsg"
    actions   = ["autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"]
  }

  # Scoped to this function's own log group. Built from var.name_prefix
  # directly (not aws_lambda_function.failover.function_name) to avoid
  # a circular dependency: this policy must exist before the function
  # that references this role.
  statement {
    sid = "LambdaLogging"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.name_prefix}-nat-failover:*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_failover" {
  name_prefix = "${var.name_prefix}-nat-failover-"
  role        = aws_iam_role.lambda_failover.id
  policy      = data.aws_iam_policy_document.lambda_failover.json
}

resource "aws_lambda_function" "failover" {
  function_name    = "${var.name_prefix}-nat-failover"
  filename         = data.archive_file.lambda_failover.output_path
  source_code_hash = data.archive_file.lambda_failover.output_base64sha256
  handler          = "lambda_failover.handler"
  runtime          = "python3.13"
  role             = aws_iam_role.lambda_failover.arn
  timeout          = 10

  environment {
    variables = {
      ASG_NAME = aws_autoscaling_group.nat.name
    }
  }

  tags = var.tags
}

# Matches Spot interruption warning events by event type only, not by
# instance/ASG: the event carries just an instance ID, nothing ASG-
# related, so EventBridge's pattern language can't filter on dynamic ASG
# membership. lambda_failover.py's is_asg_member() is the authoritative
# filter instead.
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  # EventBridge rule names cap at 64 chars, and name_prefix's random
  # suffix already consumes 26 — keep this suffix short so name_prefix
  # retains headroom.
  name_prefix = "${var.name_prefix}-spot-interrupt-"
  description = "EC2 Spot Instance Interruption Warning -> NAT instance proactive failover Lambda."

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption_lambda" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "${var.name_prefix}-nat-failover"
  arn       = aws_lambda_function.failover.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.spot_interruption.arn
}
