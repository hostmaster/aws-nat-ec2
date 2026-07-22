variable "name_prefix" {
  type        = string
  description = "Prefix for resource names and tags."

  validation {
    condition     = length(var.name_prefix) > 0
    error_message = "name_prefix must not be empty."
  }

  # Tightest constraint: aws_cloudwatch_event_rule's 64-char name cap,
  # minus its own 16-char static suffix and Terraform's 26-char random
  # suffix, leaves 22 — 20 keeps a margin. Otherwise a too-long value
  # passes plan/validate and only fails as a raw AWS API 400 mid-apply.
  validation {
    condition     = length(var.name_prefix) <= 20
    error_message = "name_prefix must be 20 characters or fewer — combined with this module's own resource-name suffixes and Terraform's name_prefix random suffix, a longer value can exceed AWS's 64-character limit on EventBridge rule and IAM role names."
  }
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC ID."
}

variable "public_subnet_id" {
  type        = string
  description = "Existing public subnet the NAT instance runs in. AZ is derived from this subnet."
}

variable "private_route_table_ids" {
  type        = list(string)
  description = "Route table IDs to repoint at the active NAT instance."

  validation {
    condition     = length(var.private_route_table_ids) > 0
    error_message = "At least one private route table ID must be provided."
  }
}

variable "architecture" {
  type        = string
  description = "\"x86_64\" or \"arm64\". Drives AMI SSM parameter and default instance types."
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be either \"x86_64\" or \"arm64\"."
  }
}

variable "instance_types" {
  type        = list(string)
  description = "Candidate instance types for the ASG mixed-instances policy. Defaults to an architecture-based list (resolved from `architecture` in compute.tf) when left null."
  default     = null
}

variable "use_spot" {
  type        = bool
  description = "Whether to prefer Spot capacity."
  default     = true
}

variable "eip_allocation_id" {
  type        = string
  description = "Bring-your-own EIP allocation ID. If null, the module allocates a new EIP."
  default     = null
}

variable "release_eip_on_destroy" {
  type        = bool
  description = "Whether the module-allocated EIP is released on terraform destroy. Ignored if eip_allocation_id is supplied (caller owns lifecycle)."
  default     = true
}

variable "allow_inbound_cidrs" {
  type        = list(string)
  description = "Optional additional ingress CIDRs on the NAT security group, beyond the default (no inbound from the internet)."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to all resources."
  default     = {}
}
