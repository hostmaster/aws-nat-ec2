# eip.tf — persistent Elastic IP.
#
# EIP ownership: a null eip_allocation_id (default) means the module
# allocates and owns aws_eip.nat; a supplied one is read via a data
# source only, and lifecycle stays with the caller.
#
# release_eip_on_destroy: lifecycle arguments must be static, so this
# can't gate destroy behavior directly — aws_eip.nat is always
# destroyed by a normal `terraform destroy` regardless of this
# variable's value. To keep the EIP alive across a destroy, remove it
# from state first:
#   terraform state rm '<module address>.aws_eip.nat[0]'
# It then becomes unmanaged and must be reimported or released later.
# Ignored entirely when eip_allocation_id is supplied (BYO) — the
# caller already owns that lifecycle.

resource "aws_eip" "nat" {
  count = var.eip_allocation_id == null ? 1 : 0

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat" })
}

data "aws_eip" "byo" {
  count = var.eip_allocation_id != null ? 1 : 0

  id = var.eip_allocation_id
}

locals {
  eip_allocation_id = var.eip_allocation_id != null ? data.aws_eip.byo[0].id : aws_eip.nat[0].id
  eip_public_ip     = var.eip_allocation_id != null ? data.aws_eip.byo[0].public_ip : aws_eip.nat[0].public_ip
}
