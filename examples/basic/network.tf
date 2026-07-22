# network.tf — throwaway VPC/subnet/route-table topology for this
# fixture ONLY. The reusable module (../..) never creates network
# topology; this fixture is the one deliberate exception, since
# verifying the module requires something real to point it at.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = data.aws_availability_zones.available.names[0]
}

resource "aws_vpc" "this" {
  cidr_block           = "10.90.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name_prefix }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name_prefix }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.90.0.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.90.1.0/24"
  availability_zone = local.az

  tags = { Name = "${var.name_prefix}-private" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Placeholder 0.0.0.0/0 route, pointed at the IGW only as a bootstrap
# value: the NAT module's bootstrap script only calls ec2:ReplaceRoute,
# never CreateRoute, which needs a pre-existing route to replace. Once
# the NAT instance boots, it repoints this at itself; ignore_changes
# stops Terraform from fighting the boot script over the target on
# every later plan. Briefly routing "private" traffic via the IGW
# during bring-up is an accepted compromise for a disposable test
# fixture only.
resource "aws_route" "private_default_placeholder" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id

  lifecycle {
    # instance_id is provider-computed-only in this aws_route schema
    # (no configured value ever exists for it, so it can't appear
    # here) — the boot script's instance-targeted ReplaceRoute call
    # surfaces back through network_interface_id instead (AWS resolves
    # an instance-targeted route to that instance's ENI), which is why
    # that one's listed.
    ignore_changes = [
      gateway_id,
      network_interface_id,
      vpc_peering_connection_id,
      transit_gateway_id,
      nat_gateway_id,
    ]
  }
}

# SSM/EC2Messages/SSMMessages interface endpoints. This fixture's VPC
# has no other path for Session Manager's control/data channel, so
# without these the private test instance's SSM access depends on the
# NAT instance too, same as its internet egress. The persistent-VPC
# cost tradeoff this implies doesn't apply here — this VPC is created
# and destroyed only for a verification run.
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name_prefix}-endpoints-"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-endpoints" }
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ec2messages", "ssmmessages"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-${each.key}" }
}
