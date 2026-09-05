"""Unit tests for lambda_spot_fallback (stdlib only — no pytest dependency)."""

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

import lambda_spot_fallback as fallback  # noqa: E402


def spot_only_group(*, instances=None, min_size=1):
    return {
        "MinSize": min_size,
        "MixedInstancesPolicy": {
            "LaunchTemplate": {
                "LaunchTemplateSpecification": {
                    "LaunchTemplateId": "lt-abc",
                    "Version": "$Latest",
                },
                "Overrides": [{"InstanceType": "t3.nano"}],
            },
            "InstancesDistribution": {
                "OnDemandBaseCapacity": 0,
                "OnDemandPercentageAboveBaseCapacity": 0,
                "SpotAllocationStrategy": "price-capacity-optimized",
            },
        },
        "Instances": instances or [],
    }


class TestShouldProcessEvent(unittest.TestCase):
    def test_empty_event_is_manual_invoke(self):
        self.assertTrue(fallback.should_process_event({}))

    def test_force_flag(self):
        self.assertTrue(fallback.should_process_event({"force": True}))

    def test_cloudwatch_alarm_state(self):
        self.assertTrue(
            fallback.should_process_event(
                {
                    "source": "aws.cloudwatch",
                    "alarmData": {"state": {"value": "ALARM"}},
                }
            )
        )

    def test_cloudwatch_ok_ignored(self):
        self.assertFalse(
            fallback.should_process_event(
                {
                    "source": "aws.cloudwatch",
                    "alarmData": {"state": {"value": "OK"}},
                }
            )
        )


class TestShouldFlipToOnDemand(unittest.TestCase):
    def test_healthy_asg_no_flip(self):
        group = spot_only_group(instances=[{"LifecycleState": "InService", "InstanceId": "i-1"}])
        self.assertFalse(fallback.should_flip_to_on_demand(group))

    def test_pending_launch_still_flips(self):
        # A pending Spot launch is not a substitute for InService capacity:
        # deferring here relies on a second alarm invocation that may never
        # come (CloudWatch only invokes alarm actions on a state
        # transition), which can leave the ASG stuck empty indefinitely if
        # this particular pending launch later fails.
        group = spot_only_group(instances=[{"LifecycleState": "Pending", "InstanceId": "i-1"}])
        self.assertTrue(fallback.should_flip_to_on_demand(group))

    def test_stuck_spot_only_flips(self):
        group = spot_only_group()
        self.assertTrue(fallback.should_flip_to_on_demand(group))

    def test_already_on_demand_no_flip(self):
        group = spot_only_group()
        group["MixedInstancesPolicy"]["InstancesDistribution"]["OnDemandPercentageAboveBaseCapacity"] = 100
        self.assertFalse(fallback.should_flip_to_on_demand(group))


class TestFlipToOnDemand(unittest.TestCase):
    @patch.object(fallback, "autoscaling")
    def test_updates_asg_when_stuck(self, mock_autoscaling):
        mock_autoscaling.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [spot_only_group()],
        }

        result = fallback.flip_to_on_demand("test-asg", client=mock_autoscaling)

        self.assertTrue(result)
        mock_autoscaling.update_auto_scaling_group.assert_called_once()
        call_kwargs = mock_autoscaling.update_auto_scaling_group.call_args.kwargs
        self.assertEqual(call_kwargs["AutoScalingGroupName"], "test-asg")
        distribution = call_kwargs["MixedInstancesPolicy"]["InstancesDistribution"]
        self.assertEqual(distribution["OnDemandPercentageAboveBaseCapacity"], 100)

    @patch.object(fallback, "autoscaling")
    def test_update_omits_launch_template(self, mock_autoscaling):
        # The Lambda's role grants only UpdateAutoScalingGroup and describe
        # permissions -- no iam:PassRole. AWS's launch-template prerequisite
        # checks (including iam:PassRole for an attached instance profile)
        # apply whenever LaunchTemplate is present in the update payload,
        # even unchanged, so it must never be included here.
        mock_autoscaling.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [spot_only_group()],
        }

        fallback.flip_to_on_demand("test-asg", client=mock_autoscaling)

        call_kwargs = mock_autoscaling.update_auto_scaling_group.call_args.kwargs
        self.assertNotIn("LaunchTemplate", call_kwargs["MixedInstancesPolicy"])

    @patch.object(fallback, "autoscaling")
    def test_no_op_when_healthy(self, mock_autoscaling):
        mock_autoscaling.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [
                spot_only_group(instances=[{"LifecycleState": "InService", "InstanceId": "i-1"}]),
            ],
        }

        result = fallback.flip_to_on_demand("test-asg", client=mock_autoscaling)

        self.assertFalse(result)
        mock_autoscaling.update_auto_scaling_group.assert_not_called()


if __name__ == "__main__":
    unittest.main()
