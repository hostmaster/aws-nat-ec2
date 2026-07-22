# iam.tf — NAT instance role/profile and policies. Lambda role is failover.tf.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  route_table_arns = [
    for rtb_id in var.private_route_table_ids :
    "arn:${local.partition}:ec2:${local.region}:${local.account_id}:route-table/${rtb_id}"
  ]

  # Exact ARN only when the caller brings their own EIP (known at plan
  # time). A module-allocated EIP's allocation ID doesn't exist until
  # eip.tf creates it, so that path falls back to an account/region
  # wildcard.
  eip_resource = (
    var.eip_allocation_id != null
    ? "arn:${local.partition}:ec2:${local.region}:${local.account_id}:elastic-ip/${var.eip_allocation_id}"
    : "arn:${local.partition}:ec2:${local.region}:${local.account_id}:elastic-ip/*"
  )
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
  # AssociateAddress/DisassociateAddress need resource entries for
  # elastic-ip, instance, and network-interface. Instance/ENI IDs can't
  # be known ahead of an ASG launch, so those two stay account/region
  # wildcards; the elastic-ip itself is scoped exactly where possible
  # (local.eip_resource).
  statement {
    sid = "SelfAssociateElasticIp"
    actions = [
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
    ]
    resources = [
      local.eip_resource,
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:network-interface/*",
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
