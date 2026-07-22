# SPEC.md — AWS NAT Instance Terraform Module

## 1. Overview

A self-hosted, cost-optimized alternative to AWS Managed NAT Gateway, distributed
as a single reusable Terraform module. Provides outbound-only IPv4 internet
access for private subnets via an EC2 instance running AL2023, with optional
Spot capacity for further cost savings. Consumed via Terragrunt, one module
instantiation per Availability Zone.

**Problem it solves:** Managed NAT Gateway is expensive at scale (hourly +
per-GB processing charges). A correctly-configured NAT instance is materially
cheaper, especially on Spot, but the existing tool the team relies on
(`terraform-aws-nat-instance`) is built on an outdated Amazon Linux version
and needs replacing.

## 2. Goals

- Provide NAT functionality (IP forwarding + MASQUERADE) equivalent to a
  Managed NAT Gateway for one or more private subnets in a single AZ.
- Run on AL2023 (standard public AMI, resolved via SSM Parameter Store —
  no custom AMI baking unless later proven unavoidable).
- Support both On-Demand and Spot capacity. When `use_spot = true`, prefer
  Spot via the Mixed Instances Policy; when Spot capacity is unavailable
  across every configured pool in the AZ, fall back to On-Demand via an
  explicit safety net (CloudWatch alarm + Lambda policy flip — see §5.5).
  A static `use_spot = false` toggle remains available
  for callers who want 100% On-Demand without the fallback machinery.
- Support both x86_64 and arm64 (Graviton) architectures.
- Minimize downtime on Spot interruption via proactive replacement
  (EventBridge spot-interruption-warning → Lambda → ASG), in addition to
  standard reactive ASG replacement on instance failure.
- Keep the NAT instance's public IP persistent (same Elastic IP) across
  instance replacement.
- Ship as a single, small-file, clearly-separated Terraform module with
  explicit inputs/outputs, consumable via Terragrunt.
- Access instances via SSM Session Manager only — no SSH, no key pairs,
  no inbound port 22.

## 3. Non-Goals

- No IPv6 / NAT64 support (IPv4 only).
- No VPC, subnet, or route table *creation* — the module consumes an
  existing VPC, an existing public subnet, and existing private-subnet
  route table IDs. It never creates network topology.
- No multi-AZ orchestration inside the module — one module call = one AZ,
  one NAT instance, one EIP. Multi-AZ is achieved by calling the module
  multiple times from Terragrunt.
- No warm-standby / always-on second instance. Exactly one running
  instance per AZ at any time (cost priority over near-zero downtime).
- No traffic shaping, QoS, bandwidth monitoring dashboards, deep packet
  inspection, or any traffic manipulation beyond standard IP forwarding
  and MASQUERADE.
- No custom AMI / Packer pipeline unless a standard AL2023 AMI proves
  insufficient. (If later required, AMI build lives in a **separate**
  repository, not this one.)
- No multi-region or multi-account support inside the module (single
  account, single region; Terragrunt handles repetition across envs).
- No automated test suite in this phase (explicitly deferred — see §11).
- No custom NAT-functionality health check (relies on standard EC2 status
  checks only, not an application-level "is NAT actually forwarding
  traffic" probe).

## 4. Architecture

### 4.1 Topology

- One NAT instance per AZ. Each module call provisions exactly one
  Auto Scaling Group (`min=max=desired=1`) in one public subnet, serving
  N private subnets (via N route table updates) in that same AZ.
- Terragrunt is responsible for invoking the module once per AZ that
  needs NAT egress, passing that AZ's public subnet and the list of
  private route table IDs to repoint.

```
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

### 4.2 Components per module instantiation (per AZ)

- **Launch Template** — AMI (SSM-resolved AL2023, arch-selectable),
  instance type(s), IAM instance profile, security group, user-data
  bootstrap script, `network_interfaces.source_dest_check = false`.
- **Auto Scaling Group** — `min=max=desired=1`, single public subnet,
  EC2 status check health check, Mixed Instances Policy (Spot when
  `use_spot = true`, 100% On-Demand when `use_spot = false`). Spot
  exhaustion fallback per §5.5 when `spot_on_demand_fallback = true`
  (the default).
- **Elastic IP** — allocated by the module by default (see §10 for the
  bring-your-own alternative), reassociated to the current instance by
  the boot script.
- **Security Group** — egress-open; ingress defaults to allowing all
  traffic from the VPC's own CIDR block(s) (looked up via the `vpc_id`
  input) — **required**, not optional: AWS security groups filter
  routed traffic through an instance's ENI too, not just traffic
  destined for the instance itself, so without this the NAT instance
  silently drops all forwarded packets regardless of `source_dest_check`
  or iptables (found via a real `apply` failure at T18, 2026-07-22).
  Nothing inbound from the internet; optional additional ingress via
  `allow_inbound_cidrs` for anything beyond the VPC's own range (e.g. a
  peered VPC or on-prem range via VPN/Direct Connect).
- **IAM Role / Instance Profile** — grants the instance permission to
  associate its own EIP, replace routes in the configured route tables,
  and use SSM Session Manager.
- **EventBridge Rule + Lambda + Lambda IAM Role** — proactive failover on
  Spot interruption warning (see §5.2).
- **CloudWatch Alarm + Fallback Lambda + Lambda IAM Role** — Spot
  exhaustion fallback to On-Demand (see §5.5). Omitted when `use_spot =
  false` or `spot_on_demand_fallback = false`.

### 4.3 Networking / data flow

- Standard, well-known NAT recipe only:
  - `net.ipv4.ip_forward=1` (persisted via `/etc/sysctl.d`)
  - `iptables -t nat -A POSTROUTING -o <primary-interface> -j MASQUERADE`
  - `source_dest_check = false` on the instance's primary ENI. Disabled
    by a boot-time `ec2:ModifyInstanceAttribute` call in the bootstrap
    script (T11, 2026-07-22), the same self-service pattern as EIP
    association/route repointing — **not** set declaratively on the
    Launch Template as originally assumed here:
    `aws_launch_template` has no argument for this at all (confirmed
    via `terraform providers schema`), so the original plan wasn't
    achievable as written.
- No ENI hot-swap, no secondary ENIs, no bandwidth/conntrack tuning.
  Traffic path is exactly: private subnet → route table `0.0.0.0/0` →
  NAT instance → MASQUERADE → internet.

## 5. Failover Behavior

### 5.1 Reactive failover (default ASG behavior)

If the NAT instance fails EC2 status checks (or is terminated for any
reason not caught by §5.2), the ASG launches a replacement instance per
its standard behavior. On boot, the new instance's bootstrap script:

1. Re-associates the persistent EIP to itself.
2. Calls `ec2:ReplaceRoute` on each configured private route table ID,
   targeting its own instance ID.

Expected downtime: roughly the new instance's boot + bootstrap time
(typically well under two minutes).

### 5.2 Proactive failover (Spot interruption warning)

To shrink the downtime window further when running on Spot:

1. An **EventBridge rule** matches `EC2 Spot Instance Interruption
   Warning` events for instances belonging to this ASG (filtered by
   instance/ASG tag).
2. The rule triggers a **Lambda function** that calls
   `autoscaling:TerminateInstanceInAutoScalingGroup` with
   `ShouldDecrementDesiredCapacity=false` on the flagged instance.
3. This causes the ASG to launch a replacement **immediately**, rather
   than waiting for the instance to actually disappear at the end of the
   two-minute Spot warning window — the replacement is typically already
   booting (or up) before the interrupted instance is reclaimed.
4. The new instance's bootstrap script performs the same EIP + route
   table steps as in §5.1.

This is a best-effort shrink of the downtime window, not a guarantee of
zero packet loss — there is no warm standby in this design (by choice,
per §3).

### 5.3 Persistent EIP

- One Elastic IP per module instantiation (per AZ), allocated once and
  never released by ordinary instance replacement.
- "Persistent" here means: the public IP a private-subnet resource
  appears to originate from stays the same across NAT instance
  replacements — not that the IP survives module deletion (see §10 for
  the destroy-behavior default).
- Reassociation is performed by the instance itself at boot time via
  `ec2:AssociateAddress`, using its own IAM instance-profile permissions.
  No Lambda or external orchestrator is involved in this step.

### 5.5 Spot exhaustion fallback (T21)

When `use_spot = true`, the ASG targets 100% Spot
(`on_demand_percentage_above_base_capacity = 0`). AWS does **not**
natively substitute On-Demand when every configured Spot pool in the AZ
is empty — the ASG keeps retrying Spot. For `desired = 1`, that leaves
private subnets without egress until Spot capacity returns.

**Mechanism:**

1. A **CloudWatch alarm** fires when `GroupInServiceInstances < 1` for a
   sustained period while Spot-only policy is active
   (`spot_on_demand_fallback = true`, the default). The ASG must publish
   this metric via `enabled_metrics` (set in `compute.tf` when fallback
   is enabled — it is opt-in per AWS).
2. A **fallback Lambda** (`scripts/lambda_spot_fallback.py`) calls
   `UpdateAutoScalingGroup` to set `OnDemandPercentageAboveBaseCapacity =
   100`, forcing the next launch as On-Demand. It skips the flip while
   instances are still `Pending`, to avoid false positives during normal
   proactive failover (§5.2).
3. The new instance's bootstrap script performs the same EIP + route
   table steps as in §5.1.

This is distinct from §5.2 (Spot *interruption*) and from toggling
`use_spot = false` (static config change). Revert to Spot after
exhaustion is **operator/Terraform-driven**; automatic revert is out of
scope.

**Why a CloudWatch alarm, not an EventBridge launch-failure event:** the
native alternative is EventBridge's `EC2 Instance Launch Unsuccessful`
(source `aws.autoscaling`) — the same style of signal already used for
`EC2 Spot Instance Interruption Warning` in §5.2. It's rejected here
because it fires per failed launch attempt across every Spot pool the
ASG retries, not once per sustained-exhaustion episode, and AWS re:Post
confirms these events can be delayed or absent during retries. A
"zero InService instances" alarm over a sustained window gives that
debounce for free, at the cost of detection latency.

**`capacity_rebalance = var.use_spot`** (`compute.tf`) is complementary:
with `max = 1` the ASG has no headroom to pre-launch a replacement
before terminating the flagged instance, so it can't get the full
zero-downtime benefit capacity rebalancing usually provides. It still
helps because it reacts to the earlier *rebalance recommendation*
signal, ahead of the 2-minute interruption warning §5.2's Lambda waits
for.

### 5.6 Route table continuity

- The bootstrap script, using the instance's own IAM role, calls
  `ec2:ReplaceRoute` for each route table ID in `private_route_table_ids`,
  setting `0.0.0.0/0` to point at its own instance ID.
- This is self-service (no separate Lambda/controller) — the same
  pattern as EIP association, run once at boot.

## 6. AMI Strategy

- No Packer, no custom AMI. The Launch Template resolves the latest
  AL2023 AMI via the public SSM parameter:
  - x86_64: `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`
  - arm64: `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`
- `architecture` input selects which parameter (and default instance
  type family) is used.
- If a future requirement can't be met by boot-time configuration alone
  (e.g. needing pre-baked packages not available in seconds at boot),
  a Packer build would live in a **separate repository** — out of scope
  for this module unless that need materializes.

## 7. Module Interface

### 7.1 Inputs

Full table, with types, defaults, and descriptions: [README.md
§Inputs](README.md#inputs) — moved there (2026-07-22) so it's visible on
the repo's GitHub front page without opening this file. README.md is the
source of truth for this table; don't duplicate it back here.

Note on `release_eip_on_destroy`: ignored if `eip_allocation_id` is
supplied (caller owns lifecycle) — see §10.

### 7.2 Outputs

Full table, with descriptions: [README.md §Outputs](README.md#outputs)
— moved there (2026-07-22) for the same GitHub front-page visibility
reason as §7.1. README.md is the source of truth; don't duplicate it
back here.

### 7.3 IAM Permissions Required

**NAT instance role** (least privilege, scoped where practical to this
instance/these resources):
- `ec2:AssociateAddress`, `ec2:DisassociateAddress`
- `ec2:ReplaceRoute`, `ec2:DescribeRouteTables`
- `ssmmessages:*`, `ec2messages:*`, `ssm:UpdateInstanceInformation`
  (SSM Session Manager access)

No `ec2:DescribeInstances` grant: the bootstrap script resolves its own
instance ID and region entirely via IMDSv2 (`/latest/meta-data/...`),
never the EC2 API, so there's no self-lookup call to authorize
(confirmed while implementing T8, 2026-07-22).

**Failover Lambda role** (proactive Spot interruption — §5.2):
- `autoscaling:TerminateInstanceInAutoScalingGroup`
- `autoscaling:DescribeAutoScalingGroups`
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

**Spot fallback Lambda role** (§5.5):
- `autoscaling:UpdateAutoScalingGroup` (scoped to this ASG's ARN)
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

## 8. Deployment Assumptions

- Single AWS account, single region per module instantiation. Multi-env
  and multi-region are handled by Terragrunt calling this module
  repeatedly with different backend/provider configuration — not by the
  module itself.
- Existing VPC, existing public subnet, and existing private route
  tables are provided by the caller; the module never creates network
  topology.
- Terraform and provider version constraints live in `versions.tf`; see
  [README.md's Requirements table](README.md#requirements) for current
  pins — not repeated here to avoid the two copies drifting out of sync.
- No key pair distribution — operators use SSM Session Manager
  (`aws ssm start-session`) for any interactive access.

## 9. Edge Cases

- **Spot capacity unavailable:** AWS Mixed Instances Policy does **not**
  fall back to On-Demand automatically — the ASG retries Spot pools
  only. **Implemented (T21):** explicit safety net (see §5.5). Widening
  `instance_types` and ASG capacity rebalancing reduce but do not
  eliminate this risk.
- **Spot interruption warning fires:** handled proactively per §5.2.
- **Instance fails EC2 status checks (non-Spot cause):** handled
  reactively per §5.1.
- **Both EIP association and route replacement must succeed for the
  instance to be considered "in service."** If either API call fails at
  boot (e.g. transient IAM/eventual-consistency issue), the bootstrap
  script should retry with backoff before giving up — a NAT instance
  that boots but never gets the EIP or route table pointed at it is
  silently useless.
- **Multiple private subnets per AZ:** supported by design — all IDs in
  `private_route_table_ids` are updated on every replacement.

## 10. Assumptions Requiring Confirmation

These two points were not explicitly settled in the requirements
interview. Sensible defaults are specified below; flag if you want
different behavior:

1. **EIP ownership:** default is the module allocates its own EIP
   (`eip_allocation_id = null`). Bring-your-own is supported as an
   escape hatch but is not the default path.
2. **EIP lifecycle on destroy:** default is `release_eip_on_destroy =
   true` — the EIP is released when the module is destroyed. If you
   want the IP to survive a destroy/recreate cycle (e.g. it's
   allowlisted in a downstream firewall), set this to `false`, in which
   case the EIP is orphaned intentionally and must be cleaned up (or
   re-imported) manually.

## 11. Testing Strategy (Deferred)

Per explicit instruction, automated test suites (bats for bootstrap
script logic, `terraform test` for module logic, pytest for the Lambda)
are **not** being built in this phase. When resumed, the intended
approach is:

- Bootstrap/failover shell logic → **bats**, run against a mocked `aws`
  CLI, asserting the correct `ec2:AssociateAddress` /
  `ec2:ReplaceRoute` calls are constructed.
- Lambda failover function → **pytest**, mocking `boto3` autoscaling
  calls.
- Terraform module → native `terraform test` with a mocked provider,
  validating variable validation rules, conditional Spot/On-Demand
  wiring, and output correctness.

## 12. Repository Layout

Small files, explicit interfaces, clean separation by concern:

```
terraform-aws-nat-instance-al2023/
├── versions.tf              # terraform + provider version constraints
├── variables.tf              # module inputs (table in README.md, §7.1 here just points there)
├── outputs.tf                 # module outputs (table in README.md, §7.2 here just points there)
├── network.tf                 # security group, subnet/AZ data sources
├── compute.tf                  # launch template, ASG, mixed instances policy
├── eip.tf                       # EIP resource (conditional on eip_allocation_id)
├── iam.tf                        # instance role, instance profile, policies
├── failover.tf                    # EventBridge rule, Lambda, Lambda IAM role
├── scripts/
│   ├── bootstrap.sh.tpl              # user-data template (NAT setup, EIP, routes)
│   └── lambda_failover.py             # proactive failover Lambda source
├── README.md
└── docs/
    ├── SPEC.md                         # this document
    ├── architecture.png                # architecture diagram, embedded in README
    └── architecture.excalidraw         # editable diagram source
```

## 13. Verification Plan (Runnable)

Manual, CLI-driven verification against a real (or disposable sandbox)
AWS account. No automated test harness in this phase, per §11 — every
step below is a copy-pasteable command.

**Prerequisites:** an existing VPC with one public subnet and at least
one private subnet + route table in the target AZ; a test EC2 instance
in the private subnet (no public IP) to act as the client whose egress
traffic transits the NAT instance; AWS CLI configured with sufficient
permissions.

**Caveat confirmed against the real dev environment this module
replaces (2026-07-09, see the legacy module's `ssm_issue.md`):** if the
VPC has no interface endpoints for `ssm`/`ec2messages`/`ssmmessages`,
every private instance's Session Manager control/data channel — not
just its internet egress — routes through the NAT instance too. A
*new* `aws ssm start-session` attempt during the replacement window in
steps 7-10 below can fail with `TargetNotConnected` even once the new
NAT instance is otherwise healthy, which would look like a module bug
but isn't one — it's this pre-existing VPC-level gap.
`describe-instance-information`'s `PingStatus: Online` is a lagging
heartbeat, not reliable evidence the data channel is actually up.
Prefer keeping the session opened in step 6 open across steps 7-10
rather than starting a fresh one, and don't treat a fresh-session
failure alone as a failed verification without also checking whether
this VPC-endpoint gap exists.

Adding the three interface endpoints is the real fix, but it is not
free and cuts against this whole project's cost motivation: interface
endpoints bill per AZ per endpoint (roughly $0.01/hr each, ~$7-8/mo)
plus per-GB data processing — three endpoints across two AZs is on the
order of $45-50+/mo, comparable to or more than the NAT instance
savings this module is chasing. Treat it as a deliberate tradeoff for
the person to weigh (blast-radius/observability during NAT replacement
vs. added fixed cost), not an automatic "just add it" — this module
doesn't own that decision or the resources (§3 non-goals), it only
needs to document the dependency.

```bash
# 1. Deploy the module (via your Terragrunt live config, or a throwaway root module)
terragrunt apply

# 2. Capture outputs
NAT_ASG=$(terragrunt output -raw nat_instance_asg_name)
NAT_EIP=$(terragrunt output -raw eip_public_ip)
echo "ASG: $NAT_ASG   EIP: $NAT_EIP"

# 3. Confirm exactly one instance is running and healthy
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$NAT_ASG" \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,LifecycleState]' \
  --output table

NAT_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$NAT_ASG" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# 4. Confirm the EIP is associated with the current instance
aws ec2 describe-addresses --public-ips "$NAT_EIP" \
  --query 'Addresses[0].InstanceId' --output text
# Expect: matches $NAT_INSTANCE_ID

# 5. Confirm the private route table(s) point at the current instance
aws ec2 describe-route-tables --route-table-ids <PRIVATE_RT_ID> \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output table
# Expect: InstanceId matches $NAT_INSTANCE_ID

# 6. From the private test instance (via SSM, not SSH), verify egress works
aws ssm start-session --target <PRIVATE_TEST_INSTANCE_ID>
#   (inside the session:)
curl -s https://checkip.amazonaws.com
#   Expect: returns $NAT_EIP

# 7. Simulate instance failure — force-terminate the current NAT instance
aws ec2 terminate-instances --instance-ids "$NAT_INSTANCE_ID"

# 8. Poll until the ASG reports a new, different, healthy instance
watch -n 5 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names '"$NAT_ASG"' \
  --query "AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,LifecycleState]" \
  --output table'
# Expect: a new InstanceId appears, reaches HealthStatus=Healthy,
# LifecycleState=InService, typically within ~1-2 minutes.

NEW_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$NAT_ASG" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# 9. Re-check EIP association and route table now point at the NEW instance
aws ec2 describe-addresses --public-ips "$NAT_EIP" \
  --query 'Addresses[0].InstanceId' --output text
# Expect: matches $NEW_INSTANCE_ID

aws ec2 describe-route-tables --route-table-ids <PRIVATE_RT_ID> \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output table
# Expect: InstanceId matches $NEW_INSTANCE_ID

# 10. Re-verify egress from the private test instance still works, with the same public IP
aws ssm start-session --target <PRIVATE_TEST_INSTANCE_ID>
curl -s https://checkip.amazonaws.com
# Expect: still returns $NAT_EIP

# 11. (Spot only) Verify proactive failover wiring exists, without waiting for a real interruption
aws events list-rules --query "Rules[?contains(Name,'spot-interruption')]" --output table
aws lambda get-function --function-name <failover_lambda_arn_from_output>
# Optionally, hand-craft and put a synthetic "EC2 Spot Instance Interruption Warning"
# event via `aws events put-events` targeting the current NAT instance ID, then repeat
# steps 8-10 and confirm replacement begins before natural termination would occur.

# 12. Teardown
terragrunt destroy
# If release_eip_on_destroy = true (default), confirm the EIP no longer appears:
aws ec2 describe-addresses --public-ips "$NAT_EIP"
# Expect: an error (address not found) — confirms clean release.
```

**Pass criteria:** steps 4, 5, 6, 9, 10 all resolve to the expected
value/output on both the original and the replacement instance, and the
gap between step 7 (termination) and step 10 succeeding again is
consistent with the downtime expectations in §5.1/§5.2.

## 14. Cost Estimate (informational)

Not a design constraint — recorded so §1's "materially cheaper" claim
is backed by real numbers instead of assumed. Figures pulled 2026-07-09
for `eu-west-1`; AWS pricing changes over time and Spot prices fluctuate
continuously — treat as directional, not exact.

**Per NAT instance (per AZ), monthly:**

| Item | Cost | Notes |
|---|---|---|
| EC2 compute, Spot (`t4g.nano`/`t3.nano`/`t3a.nano`) | ~$0.50-2/mo | Spot discount vs. on-demand is typically 60-90% but highly variable; not a stable number. |
| EC2 compute, On-Demand fallback | ~$3.35-4.16/mo | `t4g.nano` ≈ $0.0046/hr; `t3.nano` ≈ $0.0057/hr. Only paid when Spot capacity is unavailable. |
| EBS root volume (gp3, ~8GB) | ~$0.75-0.80/mo | Negligible; scales with `root_block_device` size if ever made configurable. |
| **Elastic IP (persistent)** | **$3.60/mo flat** | **Important, not in the original SPEC interview:** since Feb 2024, AWS charges $0.005/hr for *every* public IPv4 address, attached or not — this is no longer the pre-2024 "free while attached to a running instance" model. This EIP cost is now often **larger than the Spot compute cost itself**, and it is *not* optional/skippable for the module's core persistent-IP goal (§2, §5.3). |
| Failover Lambda | ~$0/mo | Comfortably inside the *permanent* free tier (1M requests + 400,000 GB-s/mo) — Spot interruptions are rare events, nowhere close to that volume. |
| Spot fallback Lambda + alarm | ~$0/mo | Same negligible volume as failover Lambda; alarm on a single ASG metric. |
| EventBridge rule | ~$0/mo | Negligible event volume for this pattern. |
| CloudWatch Logs (Lambda) | ~$0/mo (cents) | Tiny log volume. |
| ASG, Launch Template, Security Group, IAM role/profile/policy | $0/mo | No direct AWS charge for these resource types. |

**Estimated all-in, per AZ:** roughly **$5.50-6.50/mo on Spot**, or
**~$7.75/mo** if permanently running On-Demand — vs. **Managed NAT
Gateway's ~$35.04/mo base** (`$0.048/hr` in `eu-west-1`) **before any
data processing**. For 2 AZs (`eu-west-1a`+`eu-west-1b`), roughly
double both sides.

**The bigger structural saving is per-GB, not the hourly rate.**
Managed NAT Gateway charges `$0.048/GB` **on top of** standard AWS data
transfer rates (`$0.09/GB` to the internet in `eu-west-1`, after the
account-wide 100GB/mo free tier) for every byte it processes. This
module's NAT instance adds **no equivalent per-GB surcharge** — only
the same standard EC2 data-transfer-out charge that both approaches pay
identically. At meaningful traffic volumes this dominates the
comparison: e.g. 10TB/mo through a NAT Gateway costs an *extra*
~$480/mo in processing fees alone that this module's approach doesn't
incur.

**Operational consequence of the `release_eip_on_destroy = false`
escape hatch (T6):** an intentionally-orphaned EIP is not free to leave
sitting around — under the current pricing model it keeps costing
$3.60/mo indefinitely until it's manually released, unlike the old
"idle EIPs cost, attached EIPs are free" assumption that may have
informed the original default.

**Not counted here, and deliberately out of this module's cost
scope** (§3 non-goals — VPC-level resources, not owned by this module):
VPC interface endpoints for SSM/EC2Messages/SSMMessages, if added per
the §13 caveat above, add roughly **$45-50+/mo** for 3 endpoints across
2 AZs (~$0.01/hr per endpoint per AZ + data processing) — a real,
separate tradeoff for the person to weigh against this module's own
savings, not a cost this module itself introduces.
