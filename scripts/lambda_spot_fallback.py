"""Spot exhaustion fallback to On-Demand.

Triggered by a CloudWatch alarm when the NAT ASG has zero InService
instances while still configured for Spot-only capacity. Flips the
Mixed Instances Policy to 100% On-Demand so the next launch attempt
succeeds.

ASG_NAME is set by Terraform (spot_fallback.tf) as this function's
environment variable.
"""

import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

autoscaling = boto3.client("autoscaling")

ON_DEMAND_PERCENTAGE_FULL = 100


def should_process_event(event):
    """Return True for CloudWatch ALARM transitions or direct/manual invokes."""
    if not event or event.get("force") is True:
        return True
    if event.get("source") != "aws.cloudwatch":
        logger.info("Ignoring event from source %r", event.get("source"))
        return False
    state = event.get("alarmData", {}).get("state", {}).get("value")
    if state != "ALARM":
        logger.info("Ignoring CloudWatch event in state %r (not ALARM)", state)
        return False
    return True


def describe_asg(asg_name, client=autoscaling):
    """Return the single ASG dict, or None if it does not exist."""
    response = client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    groups = response.get("AutoScalingGroups", [])
    return groups[0] if groups else None


def is_spot_only_distribution(instances_distribution):
    """Return True when the ASG is configured for 100% Spot above base."""
    if not instances_distribution:
        return False
    base = instances_distribution.get("OnDemandBaseCapacity", 0)
    percentage = instances_distribution.get("OnDemandPercentageAboveBaseCapacity", 100)
    return base == 0 and percentage == 0


def has_launch_in_progress(group):
    """Return True when the ASG still has instances launching."""
    pending_states = {"Pending", "Pending:Wait", "Pending:Proceed", "Warming"}
    for instance in group.get("Instances", []):
        if instance.get("LifecycleState") in pending_states:
            return True
    return False


def in_service_count(group):
    """Return the number of InService instances in the group."""
    return sum(
        1
        for instance in group.get("Instances", [])
        if instance.get("LifecycleState") == "InService"
    )


def should_flip_to_on_demand(group):
    """Return True when Spot-only ASG is stuck with no healthy or pending capacity."""
    min_size = group.get("MinSize", 1)
    if in_service_count(group) >= min_size:
        return False

    mixed_policy = group.get("MixedInstancesPolicy")
    if not mixed_policy:
        logger.info("ASG has no MixedInstancesPolicy, nothing to flip")
        return False

    distribution = mixed_policy.get("InstancesDistribution", {})
    if not is_spot_only_distribution(distribution):
        logger.info(
            "ASG already allows On-Demand (base=%s, percentage=%s)",
            distribution.get("OnDemandBaseCapacity"),
            distribution.get("OnDemandPercentageAboveBaseCapacity"),
        )
        return False

    if has_launch_in_progress(group):
        logger.info("ASG still has instances launching, deferring fallback")
        return False

    return True


def build_on_demand_distribution(current_distribution):
    """Build InstancesDistribution for 100% On-Demand while preserving Spot strategy."""
    return {
        "OnDemandBaseCapacity": 0,
        "OnDemandPercentageAboveBaseCapacity": ON_DEMAND_PERCENTAGE_FULL,
        "SpotAllocationStrategy": current_distribution.get(
            "SpotAllocationStrategy",
            "price-capacity-optimized",
        ),
    }


def flip_to_on_demand(asg_name, client=autoscaling):
    """Flip a Spot-only ASG to 100% On-Demand, preserving its launch template overrides."""
    group = describe_asg(asg_name, client=client)
    if group is None:
        logger.warning("ASG %s not found", asg_name)
        return False

    if not should_flip_to_on_demand(group):
        return False

    mixed_policy = group["MixedInstancesPolicy"]
    new_distribution = build_on_demand_distribution(mixed_policy.get("InstancesDistribution", {}))

    client.update_auto_scaling_group(
        AutoScalingGroupName=asg_name,
        MixedInstancesPolicy={
            "LaunchTemplate": mixed_policy["LaunchTemplate"],
            "InstancesDistribution": new_distribution,
        },
    )
    logger.info("Flipped %s to 100%% On-Demand (Spot exhaustion fallback)", asg_name)
    return True


def handler(event, context):
    if not should_process_event(event):
        return

    asg_name = os.environ["ASG_NAME"]

    try:
        flip_to_on_demand(asg_name)
    except ClientError:
        logger.exception("Failed to flip %s to On-Demand", asg_name)
        raise
