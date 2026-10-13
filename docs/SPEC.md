# SPEC — aws-nat-ec2

## 1. Overview

Reusable Terraform module: outbound-only IPv4 internet access for private
subnets via an AL2023 EC2 NAT instance, optionally on Spot. Consumed via
Terragrunt — one module call per Availability Zone.

Managed NAT Gateway is expensive at scale (hourly + per-GB processing).
A correctly configured NAT instance is materially cheaper, especially on
Spot. This module replaces older Amazon Linux–based NAT instance tooling.

## 2. Goals

- NAT (IP forwarding + MASQUERADE) equivalent to Managed NAT Gateway for
  one or more private subnets in a single AZ.
- AL2023 public AMI via SSM Parameter Store — no custom AMI.
- Spot via Mixed Instances Policy when `use_spot = true`, with an
  explicit On-Demand safety net when Spot capacity is unavailable
  (CloudWatch alarm + Lambda). `use_spot = false` for static On-Demand.
- x86_64 and arm64 (Graviton).
- Proactive Spot-interruption replacement (EventBridge → Lambda → ASG)
  plus standard reactive ASG replacement on failure.
- Persistent public IP (Elastic IP) across instance replacements.
- Small, single Terraform module with explicit inputs/outputs.
- SSM Session Manager only — no SSH, no key pairs, no inbound port 22.

## 3. Non-Goals

- IPv6 / NAT64 (IPv4 only).
- Creating VPC, subnets, or route tables — the module consumes existing
  topology only.
- Multi-AZ orchestration inside the module — one call = one AZ, one NAT
  instance, one EIP. Multi-AZ = multiple Terragrunt calls.
- Warm standby / second always-on instance. Exactly one running instance
  per AZ (cost over near-zero downtime).
- Traffic shaping, QoS, bandwidth dashboards, DPI, or anything beyond IP
  forwarding and MASQUERADE.
- Custom AMI / Packer pipeline in this repo.
- Multi-region or multi-account logic inside the module.
- Application-level NAT health checks (EC2 status checks only).
- Full automated coverage of bootstrap shell and Terraform module logic
  (Lambda unit tests exist; bats / `terraform test` are deferred).

## 4. Architecture

### 4.1 Topology

One NAT instance per AZ. Each module call provisions one Auto Scaling
Group (`min=max=desired=1`) in one public subnet, serving N private
subnets via N route table updates in that AZ. Terragrunt invokes the
module once per AZ that needs egress.

```text
                 ┌────────────────────────────┐
                 │   AZ-a                      │
  Private Subnet │  ┌──────────────────────┐  │
  (route table)  │  │ ASG (min=max=desired=1)│ │──EIP (persistent)
        ────────►│  │  NAT instance (AL2023) │ │────────► Internet
                 │  └──────────────────────┘  │
                 │   Public Subnet             │
                 └────────────────────────────┘
        (repeat module call per AZ, via Terragrunt)
```

### 4.2 Components (per AZ)

- **Launch Template** — SSM-resolved AL2023 AMI (arch-selectable),
  instance type(s), IAM instance profile, security group, user-data
  bootstrap. `source_dest_check` is disabled at boot via
  `ec2:ModifyInstanceAttribute` (Launch Template has no argument for it).
- **Auto Scaling Group** — `min=max=desired=1`, single public subnet,
  EC2 status-check health, Mixed Instances Policy (Spot or 100%
  On-Demand). Spot exhaustion fallback when
  `spot_on_demand_fallback = true` (default).
- **Elastic IP** — allocated by the module by default (optional
  bring-your-own via `eip_allocation_id`); reassociated at boot.
- **Security Group** — egress open; ingress allows the VPC's own CIDR
  block(s) looked up from `vpc_id`. Required: security groups filter
  routed traffic through the ENI, so without VPC CIDR ingress the NAT
  silently drops forwarded packets. Optional extra ingress via
  `allow_inbound_cidrs` (peered VPC, VPN/Direct Connect, etc.). Nothing
  inbound from the internet by default.
- **IAM Role / Instance Profile** — associate EIP, replace routes, SSM.
- **EventBridge + failover Lambda** — proactive Spot interruption
  handling.
- **CloudWatch alarm + fallback Lambda** — Spot exhaustion → On-Demand.
  Omitted when `use_spot = false` or `spot_on_demand_fallback = false`.
- **SNS notifications + backstop alarms** (opt-in, BYO topic) —
  reactive/proactive failover notices, Lambda `Errors`/`Throttles`
  alarms, and a signal on the Spot-exhaustion alarm. Observability only;
  omitted when `sns_topic_arn = null`.
- **CloudWatch Log Groups** for both Lambdas — explicit
  `retention_in_days = var.log_retention_days` so neither falls back to
  AWS's never-expire default.

### 4.3 Networking

Standard NAT recipe:

- `net.ipv4.ip_forward=1` (persisted under `/etc/sysctl.d`)
- `iptables -t nat -A POSTROUTING -o <primary-interface> -j MASQUERADE`
- `source_dest_check = false` on the primary ENI (boot-time API call)

No ENI hot-swap, secondary ENIs, or conntrack tuning. Path: private
subnet → route table `0.0.0.0/0` → NAT instance → MASQUERADE → internet.

## 5. Failover Behavior

### 5.1 Reactive failover

If the instance fails EC2 status checks (or is terminated without a Spot
warning), the ASG launches a replacement. On boot the bootstrap script:

1. Re-associates the persistent EIP to itself.
2. Calls `ec2:ReplaceRoute` on each `private_route_table_ids` entry,
   targeting its own instance ID.

Expected downtime: boot + bootstrap (typically under two minutes).

### 5.2 Proactive failover (Spot interruption warning)

When running on Spot:

1. An EventBridge rule matches `EC2 Spot Instance Interruption Warning`
   for instances in this ASG (filtered by tag).
2. A Lambda calls `autoscaling:TerminateInstanceInAutoScalingGroup` with
   `ShouldDecrementDesiredCapacity=false`.
3. The ASG launches a replacement immediately — usually before the
   two-minute warning window ends — instead of waiting for reclaim.
4. The new instance runs the same EIP + route bootstrap as reactive
   failover.

Best-effort shorter downtime, not zero packet loss (no warm standby).

### 5.3 Persistent EIP

One Elastic IP per module call (per AZ), kept across ordinary instance
replacement. "Persistent" means the egress public IP seen by private
workloads stays stable — not that the IP survives module destroy (see
EIP lifecycle below). Reassociation is self-service at boot via
`ec2:AssociateAddress`; no Lambda involved.

### 5.4 Spot exhaustion fallback

When `use_spot = true`, the ASG targets 100% Spot
(`on_demand_percentage_above_base_capacity = 0`). AWS does **not**
natively substitute On-Demand when every configured Spot pool is empty —
the ASG keeps retrying Spot, leaving private subnets without egress.

Mechanism (when `spot_on_demand_fallback = true`):

1. A CloudWatch alarm fires on `GroupInServiceInstances < 1` for a
   sustained period. The ASG publishes this metric via `enabled_metrics`
   in `compute.tf` (opt-in per AWS).
2. A fallback Lambda (`scripts/lambda_spot_fallback.py`) calls
   `UpdateAutoScalingGroup` to set
   `OnDemandPercentageAboveBaseCapacity = 100`. It skips the flip while
   instances are still `Pending` (avoids false positives during proactive
   failover).
3. The new instance runs the same EIP + route bootstrap.

This is separate from Spot *interruption* failover and from setting
`use_spot = false`. Revert to Spot after exhaustion is
operator/Terraform-driven; automatic revert is out of scope.

**Why an alarm instead of EventBridge `EC2 Instance Launch Unsuccessful`:**
that event fires per failed launch attempt across every Spot pool retry,
not once per sustained exhaustion, and can be delayed or absent during
retries. A sustained zero-InService alarm provides debounce at the cost
of detection latency.

**`capacity_rebalance = var.use_spot`** (`compute.tf`) is complementary.
With `max = 1` there is no headroom to pre-launch before terminate, so
it cannot deliver full zero-downtime rebalancing, but it still reacts to
the earlier rebalance recommendation ahead of the two-minute
interruption warning.

### 5.5 Route table continuity

At boot, the instance's IAM role calls `ec2:ReplaceRoute` for each ID in
`private_route_table_ids`, pointing `0.0.0.0/0` at itself. Same
self-service pattern as EIP association.

## 6. AMI Strategy

No Packer, no custom AMI. The Launch Template resolves the latest AL2023
AMI via public SSM parameters:

- x86_64: `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`
- arm64: `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`

`architecture` selects the parameter and default instance type family.

## 7. Module Interface

### 7.1 Inputs / 7.2 Outputs

Source of truth: [README Inputs](../README.md#inputs) and
[README Outputs](../README.md#outputs). Do not duplicate the tables here.

Notes:

- `release_eip_on_destroy` is ignored when `eip_allocation_id` is set
  (caller owns lifecycle) — see EIP lifecycle below.
- A customer-managed `root_volume_kms_key_id` needs key-policy changes
  before launches succeed — see the README Inputs caveat.

### 7.3 IAM Permissions

**NAT instance role** (least privilege, scoped where practical):

- `ec2:AssociateAddress`, `ec2:DisassociateAddress`
- `ec2:ModifyInstanceAttribute` — disable `source_dest_check` at boot
- `ec2:CreateRoute`, `ec2:ReplaceRoute`, `ec2:DescribeRouteTables` —
  `CreateRoute` covers first launch into a route table with no existing
  default route (`ReplaceRoute` alone returns `InvalidParameterValue`)
- `ssmmessages:*`, `ec2messages:*`, `ssm:UpdateInstanceInformation`

No `ec2:DescribeInstances`: the bootstrap script resolves instance ID and
region via IMDSv2 only.

**Failover Lambda role** (Spot interruption):

- `autoscaling:TerminateInstanceInAutoScalingGroup`
- `autoscaling:DescribeAutoScalingGroups`
- `sns:Publish` on `var.sns_topic_arn` — only when `sns_topic_arn` is set
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

**Spot fallback Lambda role:**

- `autoscaling:UpdateAutoScalingGroup` (scoped to this ASG)
- `autoscaling:DescribeAutoScalingGroups`
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

Reactive ASG notifications and CloudWatch alarm → SNS publishes need no
module IAM role — they are AWS service integrations authorized via the
SNS topic resource policy.

## 8. Deployment Assumptions

- Single account and region per module call. Multi-env / multi-region is
  Terragrunt's job.
- Caller provides existing VPC, public subnet, and private route tables.
- Version pins live in `versions.tf` — see
  [README Requirements](../README.md#requirements).
- Operator access via SSM Session Manager (`aws ssm start-session`).

## 9. Edge Cases

- **Spot capacity unavailable:** Mixed Instances Policy does not fall
  back to On-Demand by itself. The Spot exhaustion fallback is the
  safety net; widening `instance_types` and capacity rebalancing reduce
  but do not eliminate the risk.
- **Spot interruption warning:** proactive failover.
- **Non-Spot EC2 status-check failure:** reactive failover.
- **EIP association and route replacement must both succeed** for the
  instance to be useful. Bootstrap should retry with backoff; a NAT that
  boots without EIP or routes is silently useless.
- **Multiple private subnets per AZ:** supported — every ID in
  `private_route_table_ids` is updated on each replacement.

## 10. EIP ownership and destroy behavior

1. **Ownership:** default is module-allocated EIP
   (`eip_allocation_id = null`). Bring-your-own is supported.
2. **Destroy:** `release_eip_on_destroy` defaults to `true` but is
   **documentation-only** — Terraform `lifecycle` cannot reference
   variables, so no resource reads it; `terraform destroy` always
   releases a module-allocated EIP. To keep the IP across destroy
   (e.g. allowlisted downstream), run
   `terraform state rm '<module address>.aws_eip.nat[0]'` *before*
   destroy. The EIP then becomes unmanaged and must be reimported or
   released manually. An orphaned EIP still bills (~$3.60/mo).

## 11. Testing

Committed Lambda suites (stdlib `unittest`; `boto3`/`botocore` stubbed
via `sys.modules` so no extra dependency):

```bash
python3 -m unittest tests.test_lambda_failover tests.test_lambda_spot_fallback
```

Deferred:

- Bootstrap shell → bats against a mocked `aws` CLI
- Module → `terraform test` with a mocked provider (validation rules,
  Spot/On-Demand wiring, outputs)

## 12. Repository Layout

```text
aws-nat-ec2/
├── versions.tf
├── variables.tf                  # inputs (table in README)
├── outputs.tf                    # outputs (table in README)
├── network.tf                    # security group, subnet/AZ data sources
├── compute.tf                    # launch template, ASG, mixed instances
├── eip.tf
├── iam.tf
├── failover.tf                   # EventBridge + proactive-failover Lambda
├── spot_fallback.tf              # Spot-exhaustion alarm + fallback Lambda
├── observability.tf              # SNS notifications, backstop alarms, logs
├── scripts/
│   ├── bootstrap.sh.tpl
│   ├── lambda_failover.py
│   └── lambda_spot_fallback.py
├── tests/
│   ├── test_lambda_failover.py
│   └── test_lambda_spot_fallback.py
├── examples/basic/               # verification fixture (not the module)
├── README.md
└── docs/
    ├── SPEC.md
    ├── architecture.png
    └── architecture.drawio
```

## 13. Verification Plan

Manual CLI checks against a real or sandbox AWS account.

**Prerequisites:** VPC with one public subnet and at least one private
subnet + route table in the target AZ; a private test EC2 instance (no
public IP); AWS CLI with sufficient permissions.

**SSM caveat:** if the VPC has no interface endpoints for
`ssm` / `ec2messages` / `ssmmessages`, Session Manager for private
instances also routes through the NAT. A *new*
`aws ssm start-session` during replacement (steps 7–10) can fail with
`TargetNotConnected` even when the new NAT is healthy — that is a
VPC-level gap, not a module bug. Prefer keeping the step-6 session open
across the replacement window.
`describe-instance-information` `PingStatus: Online` is a lagging
heartbeat and is not reliable proof the data channel is up.

Adding those three interface endpoints fixes SSM independence but costs
roughly $45–50+/mo for 3 endpoints across 2 AZs — often comparable to
the NAT savings. That tradeoff is outside this module's scope.

```bash
# 1. Deploy
terragrunt apply

# 2. Capture outputs
NAT_ASG=$(terragrunt output -raw nat_instance_asg_name)
NAT_EIP=$(terragrunt output -raw eip_public_ip)
echo "ASG: $NAT_ASG   EIP: $NAT_EIP"

# 3. Confirm one healthy instance
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$NAT_ASG" \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,LifecycleState]' \
  --output table

NAT_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$NAT_ASG" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# 4. EIP associated with current instance
aws ec2 describe-addresses --public-ips "$NAT_EIP" \
  --query 'Addresses[0].InstanceId' --output text
# Expect: matches $NAT_INSTANCE_ID

# 5. Private route table(s) point at current instance
aws ec2 describe-route-tables --route-table-ids <PRIVATE_RT_ID> \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output table
# Expect: InstanceId matches $NAT_INSTANCE_ID

# 6. From private test instance via SSM, verify egress
aws ssm start-session --target <PRIVATE_TEST_INSTANCE_ID>
#   (inside the session:)
curl -s https://checkip.amazonaws.com
#   Expect: returns $NAT_EIP

# 7. Force-terminate current NAT instance
aws ec2 terminate-instances --instance-ids "$NAT_INSTANCE_ID"

# 8. Poll until ASG has a new healthy instance
watch -n 5 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names '"$NAT_ASG"' \
  --query "AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,LifecycleState]" \
  --output table'
# Expect: new InstanceId, HealthStatus=Healthy, LifecycleState=InService (~1–2 min)

NEW_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$NAT_ASG" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# 9. EIP and route table point at NEW instance
aws ec2 describe-addresses --public-ips "$NAT_EIP" \
  --query 'Addresses[0].InstanceId' --output text
# Expect: matches $NEW_INSTANCE_ID

aws ec2 describe-route-tables --route-table-ids <PRIVATE_RT_ID> \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output table
# Expect: InstanceId matches $NEW_INSTANCE_ID

# 10. Re-verify egress — same public IP
aws ssm start-session --target <PRIVATE_TEST_INSTANCE_ID>
curl -s https://checkip.amazonaws.com
# Expect: still returns $NAT_EIP

# 11. (Spot only) Confirm proactive failover wiring
aws events list-rules --query "Rules[?contains(Name,'spot-interruption')]" --output table
aws lambda get-function --function-name <failover_lambda_arn_from_output>
# Optional: put a synthetic Spot interruption warning via
# `aws events put-events`, then repeat steps 8–10.

# 12. Teardown
terragrunt destroy
aws ec2 describe-addresses --public-ips "$NAT_EIP"
# Expect: address not found (module-allocated EIP released)
```

**Pass criteria:** steps 4, 5, 6, 9, and 10 match expectations on both
the original and replacement instance, and the gap from step 7 to step
10 recovering is consistent with reactive/proactive failover downtime.

## 14. Cost Estimate (informational)

Directional figures for `eu-west-1` (pulled 2026-07-09). Spot and AWS
pricing change; treat as order-of-magnitude.

**Per NAT instance (per AZ), monthly:**

| Item | Cost | Notes |
|---|---|---|
| EC2 Spot (`t4g.nano` / `t3.nano` / `t3a.nano`) | ~$0.50–2/mo | Spot discount typically 60–90%, highly variable. |
| EC2 On-Demand fallback | ~$3.35–4.16/mo | `t4g.nano` ≈ $0.0046/hr; `t3.nano` ≈ $0.0057/hr. Only when Spot is unavailable. |
| EBS root (gp3, 8 GB) | ~$0.75–0.80/mo | Always encrypted; optional CMK via `root_volume_kms_key_id` (no extra encryption charge). |
| **Elastic IP** | **$3.60/mo flat** | Since Feb 2024, $0.005/hr for every public IPv4. Often larger than Spot compute; required for persistent-IP. |
| Failover / fallback Lambdas, EventBridge, CW Logs | ~$0/mo | Negligible volume; well inside free tier. |
| ASG, Launch Template, SG, IAM | $0/mo | No direct charge. |

**All-in per AZ:** roughly **$5.50–6.50/mo on Spot**, or **~$7.75/mo**
On-Demand — vs Managed NAT Gateway **~$35.04/mo** base (`$0.048/hr`)
before data processing. Two AZs roughly double both sides.

**Per-GB dominates at scale.** Managed NAT adds `$0.048/GB` on top of
standard data transfer (`$0.09/GB` to internet in `eu-west-1` after the
account free tier). This module adds no equivalent processing surcharge
— only the same EC2 data-transfer-out charge. Example: 10 TB/mo through
a NAT Gateway is an *extra* ~$480/mo in processing fees this approach
avoids.

**Out of module scope:** SSM interface endpoints (~$45–50+/mo for 3
endpoints across 2 AZs) if added for Session Manager independence during
NAT replacement — see the verification SSM caveat.
