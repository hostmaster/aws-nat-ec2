# Spot exhaustion fallback to On-Demand (T21)

Design document for task **T21**: explicit Spot-to-On-Demand fallback when
the Auto Scaling group cannot launch a Spot instance.
**Status: implemented.**

See also: [SPEC.md §5.5](SPEC.md#55-spot-exhaustion-fallback-t21),
[SPEC.md §9](SPEC.md#9-edge-cases).

## Problem

With `use_spot = true` (the default), the ASG Mixed Instances Policy sets
`on_demand_base_capacity = 0` and
`on_demand_percentage_above_base_capacity = 0` — i.e. **100% Spot**.

AWS does **not** substitute On-Demand when every configured Spot pool in
the AZ is empty. The ASG keeps retrying Spot launches. For this module
(`min = max = desired = 1`), that means **no NAT instance** and **no
private-subnet egress** until Spot capacity returns or an operator
manually sets `use_spot = false` and forces a replacement.

This is separate from **Spot interruption** (common), which is already
handled by the proactive failover Lambda (SPEC §5.2). Exhaustion usually
surfaces **during recovery** after an interruption or termination, when
the ASG cannot fulfill the replacement Spot request.

## Verified AWS behavior

Authoritative sources agree: Mixed Instances Policy percentage/base
settings define a **fixed Spot/On-Demand ratio**, not a runtime fallback
policy.

| Source | Conclusion |
|--------|------------|
| [Mixed instances overview](https://docs.aws.amazon.com/autoscaling/ec2/userguide/mixed-instances-groups-set-up-overview.html) | On insufficient Spot capacity, ASG **retries other Spot pools** — no On-Demand substitution |
| [Capacity launch errors (re:Post)](https://repost.aws/knowledge-center/ec2-auto-scaling-launch-error-capacity) | Recommends **On-Demand base capacity** as a proactive minimum, not automatic fallback |
| [AWS re:Post (2024)](https://repost.aws/questions/QUca_6CG6lTvmgEHXsXEr8MA/asg-distribution-instances-unavailable-spot-instances) | Confirmed: native Spot→On-Demand fallback **is not possible** |

**Implication:** T21 path (b) from TASKS.md — implement an explicit safety
net and correct SPEC §9's previous assumption.

## How often does this matter?

| Event | Frequency | Handled today? |
|-------|-----------|----------------|
| Spot interruption (~2 min warning) | Relatively common on cheap types | Yes — §5.2 proactive failover |
| Spot capacity exhaustion (all pools dry in AZ) | Rarer, but realistic during AZ/regional crunches | **No** |

Risk factors for this module:

- **Single AZ** — cannot try another AZ's Spot pools (by design).
- **Small default type list** — e.g. `t3a.nano`, `t3.nano` only.
- **`desired = 1`** — one failed launch = total egress loss.

Soft mitigations (widen `instance_types`, enable ASG capacity rebalancing)
reduce frequency but do not replace a hard fallback for production NAT.

## Recommended design

### Overview

Keep Spot-first as the default. When the ASG has **zero InService
instances** for a sustained period while Spot-only policy is active,
flip the Mixed Instances Policy to **100% On-Demand** so the next launch
attempt succeeds.

```
use_spot=true (100% Spot)
        │
        ▼
  InService >= 1? ──yes──► normal operation
        │
       no (sustained)
        │
        ▼
 CloudWatch alarm fires
        │
        ▼
 Fallback Lambda: UpdateAutoScalingGroup
   (OnDemandPercentageAboveBaseCapacity = 100)
        │
        ▼
 ASG launches On-Demand instance
        │
        ▼
 Bootstrap: EIP + routes + NAT restored
```

Interaction with existing proactive failover (§5.2):

1. Spot warning → failover Lambda terminates instance.
2. ASG retries Spot → fails (exhaustion).
3. Alarm fires → fallback Lambda flips policy.
4. ASG launches On-Demand replacement.

The fallback Lambda **only updates purchase option**; it does not
terminate instances. No conflict with the existing failover Lambda.

### Components

| Resource | File | Purpose |
|----------|------|---------|
| CloudWatch alarm | `spot_fallback.tf` | `GroupInServiceInstances < 1` while Spot-only |
| Fallback Lambda | `scripts/lambda_spot_fallback.py` | Idempotent `UpdateAutoScalingGroup` |
| Lambda IAM role | `spot_fallback.tf` | `autoscaling:UpdateAutoScalingGroup` scoped to this ASG ARN |
| Alarm target | `spot_fallback.tf` | CloudWatch alarm → Lambda |

The fallback Lambda skips the flip when instances are still `Pending`, to
avoid false positives during normal proactive failover replacement (~2 min).

### Why a separate Lambda (not merge with failover)

Both approaches are valid. This design uses **two Lambdas** by default:

| | Failover Lambda (exists) | Fallback Lambda (planned) |
|---|--------------------------|---------------------------|
| Trigger | EventBridge: Spot interruption warning | CloudWatch alarm: zero healthy instances |
| API | `TerminateInstanceInAutoScalingGroup` | `UpdateAutoScalingGroup` |
| Timing | ~2 min before reclaim | After launch retries fail |

Benefits of separation: least-privilege IAM, independent failure domains,
easier CloudWatch debugging. A single combined handler is acceptable if
resource count matters more — branch on event source inside one function.

### Why CloudWatch alarm (not `INSTANCE_LAUNCH_ERROR`)

AWS re:Post confirms launch-error events can be **delayed or absent**
while the ASG keeps retrying Spot across pools. An **"zero InService
instances"** alarm is more reliable for `desired = 1`, at the cost of
detection latency.

**Proposed default:** 2-minute period × 2 evaluation periods (~4 minutes
worst case before fallback). Tunable via input (see below).

### Proposed inputs

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `spot_on_demand_fallback` | `bool` | `true` | Enable explicit fallback when `use_spot = true`. No effect when `use_spot = false`. |
| `spot_fallback_alarm_period_seconds` | `number` | `120` | CloudWatch alarm period. |
| `spot_fallback_alarm_evaluation_periods` | `number` | `2` | Consecutive breaching periods before fallback triggers. |

### Proposed outputs

| Output | Description |
|--------|-------------|
| `spot_fallback_lambda_arn` | ARN of the fallback Lambda (null if disabled). |
| `spot_fallback_alarm_arn` | ARN of the CloudWatch alarm (null if disabled). |

### Revert to Spot

**Default: manual / Terraform only.** Auto-revert (scheduled Lambda that
flips back to Spot when capacity returns) causes unnecessary churn and
is deferred to a follow-up task.

**Terraform drift:** the fallback Lambda changes the live ASG policy at
runtime. Terraform state still records Spot-only settings until you apply
a config change. A blind `terraform apply` while the ASG runs On-Demand
via fallback **resets the policy to Spot-only**
(`on_demand_percentage_above_base_capacity = 0`). After fallback fires:

- To **stay on On-Demand**, set `use_spot = false` and apply.
- To **return to Spot** once capacity has recovered, run a normal
  `terraform apply` with `use_spot = true` (default).

### Soft mitigations (ship with or before T21)

1. Widen default `instance_types` where AL2023 and regional Spot pools
   support it.
2. Set `capacity_rebalance = true` on the ASG (helps interruption, not
   exhaustion — complementary to §5.2).
3. Document single-AZ Spot pool limits in README.

## Cost impact

While fallback is active, compute runs at On-Demand rates (~$3.35-4.16/mo
for nano types in `eu-west-1`, per SPEC §14) instead of Spot
(~$0.50-2/mo). EIP cost ($3.60/mo) is unchanged. Still far below Managed
NAT Gateway.

Additional T21 resources (fallback Lambda, CloudWatch alarm) are
negligible — same order as the existing failover Lambda.

## Verification plan (Definition of Done)

### Verification

```bash
# Lambda syntax / lint
python -m py_compile scripts/lambda_spot_fallback.py
ruff check scripts/lambda_spot_fallback.py

# Unit tests (stdlib mock — no extra deps)
python -m unittest tests.test_lambda_spot_fallback

# Policy-flip smoke test against a deployed stack (replace ASG/Lambda names)
aws lambda invoke --function-name <name_prefix>-nat-spot-fallback \
  --payload '{}' /tmp/spot-fallback-out.json
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <asg_name> \
  --query 'AutoScalingGroups[0].MixedInstancesPolicy.InstancesDistribution'
```

Integration and end-to-end steps: see Verification plan below.

1. **Unit:** mocked boto3 tests — Spot-only ASG → policy updated; already
   On-Demand → no-op; fallback disabled → no-op.
2. **Integration:** invoke fallback Lambda directly against a test ASG;
   confirm `describe-auto-scaling-groups` shows 100% On-Demand.
3. **End-to-end:** force zero InService state (or impossible Spot config),
   wait for alarm, confirm On-Demand launch and egress from
   `examples/basic/` private test instance.
4. **Interaction:** with fallback active, run proactive failover invoke;
   confirm replacement stays On-Demand.

## References

- TASKS.md T21 (internal task tracker)
- T12 SNAPSHOT entry (2026-07-22) — research deferred to T21
- [cloudonaut: Fallback to on-demand if spot unavailable](https://cloudonaut.io/fallback-to-on-demand-ec2-instances-if-spot-capacity-is-unavailable/) — separate ASG pattern; this module uses a simpler single-ASG policy-flip suited to `desired = 1`
