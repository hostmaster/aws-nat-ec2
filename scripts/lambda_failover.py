"""Proactive Spot failover.

Triggered by an EventBridge rule on "EC2 Spot Instance Interruption
Warning" events. Terminates the flagged instance in its ASG with
ShouldDecrementDesiredCapacity=False so a replacement launches
immediately, rather than waiting for the natural ~2-minute Spot
interruption window to elapse.

ASG_NAME is set by Terraform (failover.tf) as this function's
environment variable. SNS_TOPIC_ARN is set the same way, only when
notifications are enabled (local.notifications_enabled) -- when unset,
the notification step is skipped, not attempted.
"""

import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

autoscaling = boto3.client("autoscaling")
sns = boto3.client("sns")

INTERRUPTION_WARNING_DETAIL_TYPE = "EC2 Spot Instance Interruption Warning"


def extract_instance_id(event):
    """Return the instance ID from a Spot interruption warning event, or None if the event doesn't match."""
    if event.get("detail-type") != INTERRUPTION_WARNING_DETAIL_TYPE:
        return None
    return event.get("detail", {}).get("instance-id")


def is_asg_member(instance_id, asg_name, client=None):
    """Return True if instance_id currently belongs to asg_name."""
    client = client or autoscaling
    response = client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    groups = response.get("AutoScalingGroups", [])
    if not groups:
        return False
    instance_ids = {instance["InstanceId"] for instance in groups[0].get("Instances", [])}
    return instance_id in instance_ids


def terminate_in_asg(instance_id, client=None):
    """Terminate instance_id via its ASG without decrementing desired capacity, so a replacement launches immediately.

    Returns True if this call performed the termination, False if the
    instance had already left the ASG (a benign race, not a failure).
    """
    client = client or autoscaling
    try:
        client.terminate_instance_in_auto_scaling_group(
            InstanceId=instance_id,
            ShouldDecrementDesiredCapacity=False,
        )
        return True
    except ClientError as e:
        # Benign race: the instance left the ASG between our own
        # is_asg_member() check and this call (e.g. natural Spot
        # reclamation won the race). The outcome we wanted — a
        # replacement launching — is already happening; re-raise
        # anything else so a genuine failure still surfaces/retries.
        if e.response.get("Error", {}).get("Code") == "ValidationError":
            logger.info("Instance %s already left its ASG, nothing to do: %s", instance_id, e)
            return False
        raise


def describe_instance(instance_id, asg_name, client=None):
    """Return asg_name's Instance dict for instance_id, or None if it isn't a current member."""
    client = client or autoscaling
    response = client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    groups = response.get("AutoScalingGroups", [])
    if not groups:
        return None
    for instance in groups[0].get("Instances", []):
        if instance["InstanceId"] == instance_id:
            return instance
    return None


def build_notification_message(instance_id, instance, asg_name, event_time):
    """Build the SNS notification body for a proactive Spot-failover termination."""
    return (
        f"Proactive Spot failover: terminating {instance_id} "
        f"(type={instance.get('InstanceType', 'unknown')}, "
        f"az={instance.get('AvailabilityZone', 'unknown')}) "
        f"in ASG {asg_name} at {event_time or 'unknown time'}."
    )


def publish_notification(topic_arn, message, client=None):
    """Publish message to topic_arn, or skip cleanly (log-only) if topic_arn is falsy."""
    if not topic_arn:
        logger.info("SNS_TOPIC_ARN not set, skipping Spot-failover notification")
        return
    client = client or sns
    client.publish(TopicArn=topic_arn, Subject="NAT instance proactive Spot failover", Message=message)


def handler(event, context):
    asg_name = os.environ["ASG_NAME"]

    instance_id = extract_instance_id(event)
    if instance_id is None:
        logger.info("Ignoring event with detail-type %r (not a Spot interruption warning)", event.get("detail-type"))
        return

    if not is_asg_member(instance_id, asg_name):
        logger.info("Ignoring interruption warning for %s: not a member of %s", instance_id, asg_name)
        return

    instance = describe_instance(instance_id, asg_name) or {}
    logger.info("Terminating %s in %s (proactive Spot failover)", instance_id, asg_name)
    terminated = terminate_in_asg(instance_id)
    if terminated:
        message = build_notification_message(instance_id, instance, asg_name, event.get("time"))
        publish_notification(os.environ.get("SNS_TOPIC_ARN"), message)
