# outputs.tf — everything needed to verify the fixture end to end.

output "nat_instance_asg_name" {
  description = "Name of the NAT instance's Auto Scaling Group."
  value       = module.nat.nat_instance_asg_name
}

output "eip_public_ip" {
  description = "The NAT instance's persistent public IP."
  value       = module.nat.eip_public_ip
}

output "private_test_instance_id" {
  description = "ID of the private test instance."
  value       = aws_instance.private_test.id
}

output "private_route_table_id" {
  description = "ID of the private route table the NAT instance repoints."
  value       = aws_route_table.private.id
}
