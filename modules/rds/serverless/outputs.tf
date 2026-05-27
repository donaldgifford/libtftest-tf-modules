#--------------------------------------------------------------
# Module outputs (consumer contract)
#
# Stable surface; renaming or removing an output breaks downstream
# remote-state consumers.
#--------------------------------------------------------------

output "cluster_identifier" {
  description = "The cluster's identifier (var.identifier_prefix). Used by downstream modules to compose the remote-state key when consuming this cluster via data.terraform_remote_state."
  value       = aws_rds_cluster.this.id
}

output "cluster_resource_id" {
  description = "The cluster's immutable AWS-internal resource ID (cluster_resource_id). Used by IAM database authentication policies (the resource segment of the iam:dbuser ARN is keyed by this value, not cluster_identifier)."
  value       = aws_rds_cluster.this.cluster_resource_id
}

output "cluster_endpoint" {
  description = "Writer endpoint hostname for the cluster. Applications connect here for read+write workloads."
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint hostname for the cluster. Aurora distributes read traffic across cluster instances; with a single instance, this resolves to the same endpoint as cluster_endpoint."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  description = "TCP port the cluster accepts connections on (5432 for aurora-postgresql, 3306 for aurora-mysql)."
  value       = aws_rds_cluster.this.port
}

output "engine" {
  description = "Cluster engine (aurora-postgresql or aurora-mysql) — passthrough so downstream modules don't need to refer back to their own var.engine."
  value       = aws_rds_cluster.this.engine
}

output "engine_version_actual" {
  description = "The engine version AWS actually applied. Important when var.engine_version was null — this output exposes the AWS-default version chosen at apply time."
  value       = aws_rds_cluster.this.engine_version_actual
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group created for this cluster. Read by sibling RDS modules that share the same subnet topology (the future read-replica module consumes this through remote state)."
  value       = aws_db_subnet_group.this.name
}

output "security_group_id" {
  description = "Security group ID of the cluster's DB-tier SG. Consumers reference this when they add their own peering ingress rules outside the module's allowed_consumer_sg_ids contract."
  value       = aws_security_group.this.id
}

output "kms_key_arn" {
  description = "KMS key ARN encrypting cluster storage at rest + the master user secret. BYO ARN (when var.kms_key_arn was non-null) or module-managed key's ARN — resolved transparently via local.kms_key_arn."
  value       = local.kms_key_arn
}

output "master_user_secret_arn" {
  description = "ARN of the AWS-managed Secrets Manager secret holding the master user password. Null when var.manage_master_user_password = false (operators wire their own secret in that opt-out path)."
  value       = try(aws_rds_cluster.this.master_user_secret[0].secret_arn, null)
}

output "db_cluster_parameter_group_name" {
  description = "Name of the cluster parameter group created for this cluster. The future read-replica module consumes this through remote state so replicas share the cluster's parameter family."
  value       = aws_rds_cluster_parameter_group.this.name
}

output "db_parameter_group_name" {
  description = "Name of the instance parameter group attached to the Serverless v2 instance."
  value       = aws_db_parameter_group.this.name
}

output "cluster_instance_identifier" {
  description = "Identifier of the single Serverless v2 cluster instance. Useful for AWS CLI / SDK operations targeting the instance directly (e.g., reboot-db-instance)."
  value       = aws_rds_cluster_instance.this.identifier
}
