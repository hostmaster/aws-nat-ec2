"""Unit tests for lambda_failover (stdlib only — no pytest dependency)."""

import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Lambda runtime bundles boto3/botocore; local tests stub them before import.
sys.modules.setdefault("boto3", MagicMock())

botocore_exceptions = types.ModuleType("botocore.exceptions")


class _ClientError(Exception):
    def __init__(self, response):
        self.response = response


botocore_exceptions.ClientError = _ClientError
sys.modules.setdefault("botocore", types.ModuleType("botocore"))
sys.modules["botocore.exceptions"] = botocore_exceptions

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import lambda_failover as failover  # noqa: E402

INTERRUPTION_EVENT = {
    "detail-type": "EC2 Spot Instance Interruption Warning",
    "time": "2026-08-13T12:00:00Z",
    "detail": {"instance-id": "i-asgmember"},
}


def asg_group(instances=None):
    return {"Instances": instances or []}


class TestExtractInstanceId(unittest.TestCase):
    def test_matching_event(self):
        self.assertEqual(failover.extract_instance_id(INTERRUPTION_EVENT), "i-asgmember")

    def test_wrong_detail_type(self):
        self.assertIsNone(failover.extract_instance_id({"detail-type": "something else"}))


class TestIsAsgMember(unittest.TestCase):
    def test_member(self):
        client = MagicMock()
        client.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [asg_group([{"InstanceId": "i-asgmember"}])],
        }
        self.assertTrue(failover.is_asg_member("i-asgmember", "test-asg", client=client))

    def test_not_member(self):
        client = MagicMock()
        client.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [asg_group([{"InstanceId": "i-other"}])],
        }
        self.assertFalse(failover.is_asg_member("i-asgmember", "test-asg", client=client))


class TestDescribeInstance(unittest.TestCase):
    def test_returns_matching_instance(self):
        client = MagicMock()
        client.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [
                asg_group([{"InstanceId": "i-asgmember", "InstanceType": "t3.nano", "AvailabilityZone": "eu-west-1a"}])
            ],
        }
        instance = failover.describe_instance("i-asgmember", "test-asg", client=client)
        self.assertEqual(instance["InstanceType"], "t3.nano")

    def test_returns_none_when_not_found(self):
        client = MagicMock()
        client.describe_auto_scaling_groups.return_value = {"AutoScalingGroups": [asg_group()]}
        self.assertIsNone(failover.describe_instance("i-asgmember", "test-asg", client=client))


class TestTerminateInAsg(unittest.TestCase):
    def test_terminate_succeeds(self):
        client = MagicMock()
        self.assertTrue(failover.terminate_in_asg("i-asgmember", client=client))
        client.terminate_instance_in_auto_scaling_group.assert_called_once_with(
            InstanceId="i-asgmember", ShouldDecrementDesiredCapacity=False
        )

    def test_benign_race_returns_false(self):
        client = MagicMock()
        client.terminate_instance_in_auto_scaling_group.side_effect = _ClientError(
            {"Error": {"Code": "ValidationError", "Message": "not in ASG"}}
        )
        self.assertFalse(failover.terminate_in_asg("i-asgmember", client=client))

    def test_other_error_reraised(self):
        client = MagicMock()
        client.terminate_instance_in_auto_scaling_group.side_effect = _ClientError(
            {"Error": {"Code": "Throttling", "Message": "slow down"}}
        )
        with self.assertRaises(_ClientError):
            failover.terminate_in_asg("i-asgmember", client=client)


class TestPublishNotification(unittest.TestCase):
    def test_publishes_when_topic_arn_set(self):
        client = MagicMock()
        failover.publish_notification("arn:aws:sns:eu-west-1:123456789012:test-topic", "hello", client=client)
        client.publish.assert_called_once_with(
            TopicArn="arn:aws:sns:eu-west-1:123456789012:test-topic",
            Subject="NAT instance proactive Spot failover",
            Message="hello",
        )

    def test_skips_when_topic_arn_unset(self):
        client = MagicMock()
        failover.publish_notification(None, "hello", client=client)
        client.publish.assert_not_called()


class TestHandler(unittest.TestCase):
    @patch.object(failover, "autoscaling")
    @patch.object(failover, "sns")
    def test_full_flow_publishes_notification(self, mock_sns, mock_autoscaling):
        mock_autoscaling.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [
                asg_group([{"InstanceId": "i-asgmember", "InstanceType": "t3.nano", "AvailabilityZone": "eu-west-1a"}])
            ],
        }

        with patch.dict("os.environ", {"ASG_NAME": "test-asg", "SNS_TOPIC_ARN": "arn:aws:sns:eu-west-1:123456789012:test-topic"}):
            failover.handler(INTERRUPTION_EVENT, None)

        mock_autoscaling.terminate_instance_in_auto_scaling_group.assert_called_once_with(
            InstanceId="i-asgmember", ShouldDecrementDesiredCapacity=False
        )
        mock_sns.publish.assert_called_once()
        message = mock_sns.publish.call_args.kwargs["Message"]
        self.assertIn("i-asgmember", message)
        self.assertIn("t3.nano", message)
        self.assertIn("eu-west-1a", message)

    @patch.object(failover, "autoscaling")
    @patch.object(failover, "sns")
    def test_no_notification_when_topic_arn_unset(self, mock_sns, mock_autoscaling):
        mock_autoscaling.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [asg_group([{"InstanceId": "i-asgmember", "InstanceType": "t3.nano"}])],
        }

        with patch.dict("os.environ", {"ASG_NAME": "test-asg"}, clear=True):
            failover.handler(INTERRUPTION_EVENT, None)

        mock_autoscaling.terminate_instance_in_auto_scaling_group.assert_called_once()
        mock_sns.publish.assert_not_called()

    @patch.object(failover, "autoscaling")
    @patch.object(failover, "sns")
    def test_non_member_ignored_no_terminate_no_publish(self, mock_sns, mock_autoscaling):
        mock_autoscaling.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [asg_group([{"InstanceId": "i-other"}])],
        }

        with patch.dict("os.environ", {"ASG_NAME": "test-asg", "SNS_TOPIC_ARN": "arn:aws:sns:eu-west-1:123456789012:test-topic"}):
            failover.handler(INTERRUPTION_EVENT, None)

        mock_autoscaling.terminate_instance_in_auto_scaling_group.assert_not_called()
        mock_sns.publish.assert_not_called()


if __name__ == "__main__":
    unittest.main()
