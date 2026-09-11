output "vpc_id" {
  description = "VPC id the API reports for the security group."
  value       = data.aws_security_group.this.vpc_id
}

output "description" {
  description = "Description the API reports."
  value       = data.aws_security_group.this.description
}

output "name_tag" {
  description = "Name tag the API reports."
  value       = data.aws_security_group.this.tags["Name"]
}

output "expected_vpc_id" {
  description = "Echo of the expected VPC id, so a caller can compare without threading it back itself."
  value       = var.vpc_id
}

output "prefix_list_rule_prefix_list_id" {
  description = "Prefix list id the EC2 API reports for the prefix-list rule."
  value       = data.aws_vpc_security_group_rule.prefix_list.prefix_list_id
}

output "prefix_list_rule_description" {
  description = "Description the EC2 API reports for the prefix-list rule."
  value       = data.aws_vpc_security_group_rule.prefix_list.description
}
