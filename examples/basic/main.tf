# main.tf — calls the NAT module against this fixture's own throwaway
# topology (network.tf), plus a private test instance for connectivity
# checks.

module "nat" {
  source = "../.."

  name_prefix             = var.name_prefix
  vpc_id                  = aws_vpc.this.id
  public_subnet_id        = aws_subnet.public.id
  private_route_table_ids = [aws_route_table.private.id]

  depends_on = [aws_route.private_default_placeholder]
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "private_test_instance" {
  name_prefix = "${var.name_prefix}-private-test-"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-private-test" }
}

data "aws_iam_policy_document" "private_test_instance_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "private_test_instance" {
  name_prefix        = "${var.name_prefix}-private-test-"
  assume_role_policy = data.aws_iam_policy_document.private_test_instance_assume_role.json
}

resource "aws_iam_role_policy_attachment" "private_test_instance_ssm" {
  role       = aws_iam_role.private_test_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "private_test_instance" {
  name_prefix = "${var.name_prefix}-private-test-"
  role        = aws_iam_role.private_test_instance.name
}

resource "aws_instance" "private_test" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = "t3.nano"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.private_test_instance.id]
  iam_instance_profile   = aws_iam_instance_profile.private_test_instance.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = { Name = "${var.name_prefix}-private-test" }
}
