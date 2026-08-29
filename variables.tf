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

  validation {
    condition     = var.instance_types == null || length(var.instance_types) > 0
    error_message = "instance_types must be null (use the architecture-based default) or a non-empty list."
  }
}

variable "use_spot" {
  type        = bool
  description = "Whether to prefer Spot capacity."
  default     = true
}

variable "spot_on_demand_fallback" {
  type        = bool
  description = "When use_spot is true, flip the ASG to 100% On-Demand via a CloudWatch alarm and Lambda if zero instances stay InService (Spot exhaustion). Ignored when use_spot is false."
  default     = true
}

variable "spot_fallback_alarm_period_seconds" {
  type        = number
  description = "CloudWatch alarm period (seconds) for Spot-exhaustion fallback. Only used when use_spot and spot_on_demand_fallback are true."
  default     = 120

  validation {
    condition     = var.spot_fallback_alarm_period_seconds >= 60 && var.spot_fallback_alarm_period_seconds <= 86400
    error_message = "spot_fallback_alarm_period_seconds must be between 60 and 86400."
  }
}

variable "spot_fallback_alarm_evaluation_periods" {
  type        = number
  description = "Consecutive breaching periods before Spot-exhaustion fallback runs. Only used when use_spot and spot_on_demand_fallback are true."
  default     = 2

  validation {
    condition     = var.spot_fallback_alarm_evaluation_periods >= 1 && var.spot_fallback_alarm_evaluation_periods <= 10
    error_message = "spot_fallback_alarm_evaluation_periods must be between 1 and 10."
  }
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

variable "root_volume_size" {
  type        = number
  description = "Root EBS volume size (GB) for the NAT instance."
  default     = 8

  validation {
    condition     = var.root_volume_size >= 8 && var.root_volume_size <= 100
    error_message = "root_volume_size must be between 8 and 100 GB."
  }
}

variable "root_volume_kms_key_id" {
  type        = string
  description = "Optional customer-managed KMS key ARN/ID for root volume encryption. If null, the account's default aws/ebs key is used. The root volume is always encrypted regardless of this value."
  default     = null
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

variable "sns_topic_arn" {
  type        = string
  description = "Bring-your-own SNS topic ARN for failover/health notifications. If null, no notifications are sent and the module creates no SNS resources."
  default     = null
}

variable "log_retention_days" {
  type        = number
  description = "Retention (days) for both Lambdas' CloudWatch Log Groups. Must be a value CloudWatch Logs accepts for retention_in_days."
  default     = 14

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of CloudWatch Logs' accepted retention_in_days values: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
}

locals {
  notifications_enabled = var.sns_topic_arn != null
}
