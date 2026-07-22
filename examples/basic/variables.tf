# variables.tf — inputs for this fixture itself (not the NAT module).

variable "region" {
  type        = string
  description = "AWS region for this throwaway verification fixture."
  default     = "eu-west-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for this fixture's own resources (VPC, subnets, test instance) — also passed through as the NAT module's own name_prefix."
  default     = "nat-example-basic"
}
