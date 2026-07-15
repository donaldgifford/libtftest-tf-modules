#--------------------------------------------------------------
# Module outputs
#
# vpc_id + private_subnet_ids are the STABLE downstream contract read
# by the RDS / EKS / EFS modules via data.terraform_remote_state.vpc
# (INV-0004 Finding 1). The remaining outputs are additive network
# facts — safe to rename before a 1.0 tag.
#--------------------------------------------------------------

output "vpc_id" {
  description = "ID of the discovered VPC. Contract output — read by every downstream RDS/EKS/EFS module's security group + subnet group."
  value       = data.aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary IPv4 CIDR block of the discovered VPC. Additive."
  value       = data.aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Sorted IDs of the private subnets (tag filter var.private_subnet_tags). Contract output — RDS DB subnet groups, EKS vpc_config, and EFS mount targets consume this. Spans >= 2 AZs when the source VPC is laid out correctly (INV-0004 Finding 4)."
  value       = local.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Sorted IDs of the public subnets (tag filter var.public_subnet_tags). Additive — no current consumer, shipped for parity with the future modules/network/vpc."
  value       = local.public_subnet_ids
}

output "private_eks_subnet_ids" {
  description = "Sorted IDs of the private EKS subnets (tag filter var.private_eks_subnet_tags) — the internal cluster IP range. Consumed by eks/cluster for aws_eks_cluster.vpc_config.subnet_ids. Distinct from private_subnet_ids (the data tier used by RDS/EFS + worker nodes)."
  value       = local.private_eks_subnet_ids
}

output "availability_zones" {
  description = "Sorted distinct AZs spanned by the private subnets. Additive — useful for callers that need to co-locate resources with the DB/compute tier."
  value       = local.availability_zones
}

output "nat_gateway_ids" {
  description = "Sorted IDs of the NAT gateways in the VPC (empty when none). Additive."
  value       = sort(data.aws_nat_gateways.this.ids)
}

output "route_table_ids" {
  description = "Sorted IDs of the route tables in the VPC (includes the main route table). Additive — the future modules/network/vpc will split public/private route-table outputs."
  value       = sort(data.aws_route_tables.this.ids)
}

output "internet_gateway_id" {
  description = "ID of the VPC's attached internet gateway, or null when var.lookup_internet_gateway = false / none is attached. Additive."
  value       = local.internet_gateway_id
}
