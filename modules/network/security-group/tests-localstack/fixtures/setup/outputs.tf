output "vpc_id" {
  description = "VPC the module under test places its security group in."
  value       = module.vpc.vpc_id
}

output "prefix_list_id" {
  description = "Populated managed prefix list for the live prefix-list rule under test."
  value       = aws_ec2_managed_prefix_list.corp.id
}

output "peer_security_group_id" {
  description = "Peer SG for the referenced_security_group_id rule under test."
  value       = aws_security_group.peer.id
}

output "bucket_name" {
  description = "Remote-state bucket the reference-vpc fixture created and seeded."
  value       = module.vpc.bucket_name
}
