#--------------------------------------------------------------
# Outputs — the nine-output vpc-lookup contract (so composing
# fixtures can reference the topology directly) plus the state
# bucket name (so they can write additional state objects into it).
#--------------------------------------------------------------

output "vpc_id" {
  description = "The reference VPC's ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private (data-tier) subnet IDs — the tier RDS/EFS and EKS worker nodes consume."
  value       = aws_subnet.private[*].id
}

output "private_eks_subnet_ids" {
  description = "Private EKS subnet IDs — the internal EKS control-plane IP range."
  value       = aws_subnet.private_eks[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = aws_subnet.public[*].id
}

output "vpc_cidr_block" {
  description = "The reference VPC's CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "The availability zones the three subnet tiers span."
  value       = local.azs
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs."
  value       = [aws_nat_gateway.this.id]
}

output "route_table_ids" {
  description = "Route table IDs (public + private)."
  value       = [aws_route_table.public.id, aws_route_table.private.id]
}

output "internet_gateway_id" {
  description = "Internet gateway ID."
  value       = aws_internet_gateway.this.id
}

output "bucket_name" {
  description = "Name of the S3 bucket holding the seeded VPC remote state, so composing fixtures (proxy, read-replica) can write additional state objects into the same bucket."
  value       = aws_s3_bucket.state.id
}
