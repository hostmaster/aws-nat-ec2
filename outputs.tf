# outputs.tf — module outputs.

output "nat_instance_asg_name" {
  description = "Name of the Auto Scaling Group."
  value       = aws_autoscaling_group.nat.name
}

output "nat_instance_security_group_id" {
  description = "Security Group ID attached to the NAT instance."
  value       = aws_security_group.nat.id
}

output "eip_public_ip" {
  description = "The persistent public IP address."
  value       = local.eip_public_ip
}

output "eip_allocation_id" {
  description = "Allocation ID of the EIP in use (module-created or BYO passthrough)."
  value       = local.eip_allocation_id
}

output "iam_role_arn" {
  description = "ARN of the NAT instance's IAM role."
  value       = aws_iam_role.nat_instance.arn
}

output "failover_lambda_arn" {
  description = "ARN of the proactive-failover Lambda function."
  value       = aws_lambda_function.failover.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the Spot-interruption-warning EventBridge rule."
  value       = aws_cloudwatch_event_rule.spot_interruption.arn
}
