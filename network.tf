# network.tf — subnet/AZ data sources, NAT security group.

data "aws_subnet" "public" {
  id = var.public_subnet_id

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id
      error_message = "public_subnet_id does not belong to vpc_id."
    }
  }
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  public_subnet_az = data.aws_subnet.public.availability_zone
}

resource "aws_security_group" "nat" {
  name_prefix = "${var.name_prefix}-nat-"
  description = "NAT instance security group: egress-open; ingress limited to the VPC own CIDR (required for NAT forwarding) plus any caller-opted-in allow_inbound_cidrs; nothing from the internet."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "NAT egress: allow all outbound."
}

# Required, not optional: security groups filter routed traffic through
# an ENI too, not just traffic addressed to the instance itself. Without
# this, source_dest_check=false and correct iptables config still can't
# save a packet dropped at the SG layer before it ever reaches iptables.
# All-protocol on purpose — the NAT must forward arbitrary protocols/
# ports originating from the private subnet; iptables is the layer to
# filter further if ever needed.
#
# Scoped to the VPC's primary CIDR only, not for_each over
# cidr_block_associations: when the caller's VPC is created in the same
# apply as this module call, its id (and everything read from it,
# including the associations list) is unknown until apply, and for_each
# can't build a key set from an unknown value. A single resource can
# still take an unknown-at-plan-time attribute value fine — it just
# can't use one to decide how many instances to create. Secondary VPC
# CIDR blocks are consequently not covered.
resource "aws_vpc_security_group_ingress_rule" "vpc_cidr" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  ip_protocol       = "-1"
  description       = "NAT ingress: allow all traffic from this VPC own primary CIDR block; required for the instance to forward traffic, not just an internet-facing rule."
}

# Additional, beyond the VPC's own CIDR above — an explicit,
# caller-opted-in escape hatch (e.g. ingress from a peered VPC or
# on-prem range via VPN/Direct Connect), not needed for ordinary NAT
# function within a single VPC.
resource "aws_vpc_security_group_ingress_rule" "allow_inbound" {
  for_each = toset(var.allow_inbound_cidrs)

  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
  description       = "Optional additional ingress CIDR (allow_inbound_cidrs)."
}
