# iam.tf — NAT instance role/profile and policies, plus the Lambda
# assume-role policy shared by both Lambda roles (failover.tf,
# spot_fallback.tf) since it's identical for each.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# Shared by aws_iam_role.lambda_failover (failover.tf) and
# aws_iam_role.lambda_spot_fallback (spot_fallback.tf) — both Lambdas
# assume their role the same way, so one document covers both.
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  route_table_arns = [
    for rtb_id in var.private_route_table_ids :
    "arn:${local.partition}:ec2:${local.region}:${local.account_id}:route-table/${rtb_id}"
  ]

  # local.eip_allocation_id (eip.tf) already resolves to either the BYO
  # data source's id or the module-allocated aws_eip.nat[0].id — an
  # apply-time-known value is fine to reference here, so this is always
  # scoped exactly to the one EIP this module actually uses, no wildcard
  # needed.
  eip_resource = "arn:${local.partition}:ec2:${local.region}:${local.account_id}:elastic-ip/${local.eip_allocation_id}"
}

data "aws_iam_policy_document" "nat_instance_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nat_instance" {
  name_prefix        = "${var.name_prefix}-nat-instance-"
  assume_role_policy = data.aws_iam_policy_document.nat_instance_assume_role.json
  tags               = var.tags
}

resource "aws_iam_instance_profile" "nat_instance" {
  name_prefix = "${var.name_prefix}-nat-instance-"
  role        = aws_iam_role.nat_instance.name
  tags        = var.tags
}

data "aws_iam_policy_document" "nat_instance" {
  # AssociateAddress/DisassociateAddress need resource entries for both
  # elastic-ip and instance. The instance ID isn't known ahead of an ASG
  # launch, so that stays an account/region wildcard; the elastic-ip
  # itself is scoped exactly (local.eip_resource). bootstrap.sh.tpl only
  # ever associates by --instance-id, never --network-interface-id, so
  # no network-interface resource entry is needed.
  statement {
    sid = "SelfAssociateElasticIp"
    actions = [
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
    ]
    resources = [
      local.eip_resource,
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
    ]
  }

  # aws_launch_template has no argument to disable source/dest check
  # declaratively, so the instance does it on itself at boot instead —
  # same self-service pattern as EIP association above. Scoped the same
  # way: the instance ID isn't known ahead of an ASG launch.
  statement {
    sid       = "SelfDisableSourceDestCheck"
    actions   = ["ec2:ModifyInstanceAttribute"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"]
  }

  # CreateRoute/ReplaceRoute both support resource-level permissions on
  # route-table — scoped exactly to the route tables this module was told
  # to manage, no wildcard needed. CreateRoute covers first-ever launch
  # into a route table with no pre-existing default route (ReplaceRoute
  # alone rejects that case); ReplaceRoute covers every later reboot or
  # failover, once a route already exists.
  statement {
    sid       = "SelfRepointRouteTables"
    actions   = ["ec2:CreateRoute", "ec2:ReplaceRoute"]
    resources = local.route_table_arns
  }

  # List-access-level action with no resource-level permissions defined
  # for it — "*" is the only valid Resource value.
  statement {
    sid       = "SelfLookup"
    actions   = ["ec2:DescribeRouteTables"]
    resources = ["*"]
  }

  # Matches AWS's own AmazonSSMManagedInstanceCore managed policy. None
  # of these three actions support resource-level scoping.
  statement {
    sid = "SsmSessionManager"
    actions = [
      "ssmmessages:*",
      "ec2messages:*",
      "ssm:UpdateInstanceInformation",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "nat_instance" {
  name_prefix = "${var.name_prefix}-nat-instance-"
  role        = aws_iam_role.nat_instance.id
  policy      = data.aws_iam_policy_document.nat_instance.json
}
