# aws-nat-ec2

A self-hosted, Spot-capable, AL2023-based NAT instance — a cheaper
alternative to AWS Managed NAT Gateway for outbound-only internet access
from private subnets. One module call provisions exactly one NAT
instance (via an Auto Scaling Group) and one persistent Elastic IP in a
single Availability Zone; call the module once per AZ that needs NAT
egress.

Highlights:

- AL2023, resolved via the public SSM AMI parameter — no custom AMI.
- Spot capacity by default, with reactive (ASG replacement) and
  proactive (Spot-interruption-warning → Lambda) failover.
- The public IP stays the same across every instance replacement.
- SSM Session Manager only — no SSH, no key pairs, no bastion host.

Inputs and outputs are documented below. See [SPEC.md](docs/SPEC.md) for the
full design rationale, IAM permissions (§7.3), and the runnable manual
verification plan (§13).

## Architecture

![Architecture diagram](docs/architecture.png)

Editable source: [`docs/architecture.drawio`](docs/architecture.drawio)
— open it at [diagrams.net](https://app.diagrams.net) (File → Open From
→ Device) or in the draw.io VS Code/desktop app.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9 |
| aws provider | ~> 6.0 |
| archive provider | ~> 2.4 |

This module has no `provider` block of its own (standard reusable-module
convention) — the caller's Terragrunt/root-module configuration supplies
AWS credentials and region.

## Usage (Terragrunt)

The module never creates VPC/subnet/route-table topology — it consumes
an existing public subnet (for the NAT instance) and existing private
route table(s) to repoint at it. A minimal `terragrunt.hcl`:

```hcl
terraform {
  # Replace with wherever this module actually lives — a git URL
  # (e.g. "git::https://github.com/<org>/<repo>.git//?ref=v1.0.0"), a
  # relative local path, or a Terraform registry source.
  source = "<path-or-git-url-to-this-module>"
}

dependency "vpc" {
  config_path = "../vpc"
}

dependency "subnets" {
  config_path = "../subnets"
}

inputs = {
  name_prefix             = "myapp-dev"
  vpc_id                  = dependency.vpc.outputs.vpc_id
  public_subnet_id        = dependency.subnets.outputs.public_subnet_ids[0]
  private_route_table_ids = [dependency.subnets.outputs.private_route_table_ids[0]]

  # Optional — shown at their defaults for clarity; omit any of these
  # to use the default. See the Inputs table below for the full list.
  architecture        = "x86_64" # or "arm64"
  use_spot            = true
  allow_inbound_cidrs = []
  tags = {
    environment = "dev"
  }
}
```

For a second AZ, add a second Terragrunt unit calling this same module
with that AZ's `public_subnet_id`/`private_route_table_ids` — this
module deliberately has no multi-AZ logic of its own (SPEC §3/§4.1).

## Inputs

At minimum, every module call must supply `name_prefix`, `vpc_id`,
`public_subnet_id`, and `private_route_table_ids`; everything else has a
sensible default.

| Variable | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | — (required) | Prefix for resource names and tags. Must be 20 characters or fewer (validated) — combined with this module's own resource-name suffixes and Terraform's `name_prefix` random suffix, a longer value can exceed AWS's 64-character limit on EventBridge rule / IAM role names. |
| `vpc_id` | `string` | — (required) | Existing VPC ID. |
| `public_subnet_id` | `string` | — (required) | Existing public subnet the NAT instance runs in. AZ is derived from this subnet. |
| `private_route_table_ids` | `list(string)` | — (required) | Route table IDs to repoint at the active NAT instance. |
| `architecture` | `string` | `"x86_64"` | `"x86_64"` or `"arm64"`. Drives AMI SSM parameter and default instance types. |
| `instance_types` | `list(string)` | arch-based default (e.g. `["t3a.nano","t3.nano"]` or `["t4g.nano"]`) | Candidate instance types for the ASG mixed-instances policy. |
| `use_spot` | `bool` | `true` | Whether to prefer Spot capacity. |
| `eip_allocation_id` | `optional(string)` | `null` | Bring-your-own EIP allocation ID. If `null`, the module allocates a new EIP. |
| `release_eip_on_destroy` | `bool` | `true` | Whether the module-allocated EIP is released on `terraform destroy`. Ignored if `eip_allocation_id` is supplied (caller owns lifecycle). |
| `allow_inbound_cidrs` | `list(string)` | `[]` | Optional additional ingress CIDRs on the NAT security group, beyond the default (no inbound from the internet). |
| `tags` | `map(string)` | `{}` | Additional tags applied to all resources. |

## Outputs

| Output | Description |
|---|---|
| `nat_instance_asg_name` | Name of the Auto Scaling Group. |
| `nat_instance_security_group_id` | Security Group ID attached to the NAT instance. |
| `eip_public_ip` | The persistent public IP address. |
| `eip_allocation_id` | Allocation ID of the EIP in use (module-created or BYO passthrough). |
| `iam_role_arn` | ARN of the NAT instance's IAM role. |
| `failover_lambda_arn` | ARN of the proactive-failover Lambda function. |
| `eventbridge_rule_arn` | ARN of the Spot-interruption-warning EventBridge rule. |
