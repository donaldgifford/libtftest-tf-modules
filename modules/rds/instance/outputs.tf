#--------------------------------------------------------------
# Module outputs (consumer contract)
#
# Stable surface; renaming or removing an output breaks downstream
# remote-state consumers.
#--------------------------------------------------------------

output "instance_identifier" {
  description = "The instance's identifier (var.identifier_prefix). Used by downstream modules to compose the remote-state key and by the RDS Proxy module as target_identifier for target_type = \"rds-instance\"."
  value       = aws_db_instance.this.identifier
}

output "endpoint" {
  description = "Connection endpoint in address:port form. Applications connect here for read+write workloads."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname of the instance (the endpoint without the port). Useful when the port is supplied separately."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "TCP port the instance accepts connections on (5432 for postgres, 3306 for mysql, or var.db_port when overridden)."
  value       = aws_db_instance.this.port
}

output "engine" {
  description = "Instance engine (postgres or mysql) — passthrough so downstream modules don't need to refer back to their own var.engine. Read by the RDS Proxy module to derive engine_family + port."
  value       = aws_db_instance.this.engine
}

output "engine_version_actual" {
  description = "The engine version AWS actually applied. Important when var.engine_version was null — this output exposes the AWS-default version chosen at apply time."
  value       = aws_db_instance.this.engine_version_actual
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group created for this instance. Read by sibling RDS modules that share the same subnet topology."
  value       = aws_db_subnet_group.this.name
}

output "db_parameter_group_name" {
  description = "Name of the instance parameter group attached to the instance."
  value       = aws_db_parameter_group.this.name
}

output "security_group_id" {
  description = "Security group ID of the instance's DB-tier SG. Consumers reference this when they add their own peering ingress rules outside the module's allowed_consumer_sg_ids contract. Also read by the RDS Proxy module."
  value       = aws_security_group.this.id
}

output "kms_key_arn" {
  description = "KMS key ARN encrypting instance storage at rest + the master user secret. BYO ARN (when var.kms_key_arn was non-null) or module-managed key's ARN — resolved transparently via local.kms_key_arn."
  value       = local.kms_key_arn
}

output "master_user_secret_arn" {
  description = "ARN of the AWS-managed Secrets Manager secret holding the master user password. Null when var.manage_master_user_password = false (operators wire their own secret in that opt-out path). Read by the RDS Proxy module to source database credentials."
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
}

#--------------------------------------------------------------
# RDS Proxy composition outputs (DESIGN-0010 Q11-a / IMPL-0010 Phase 2)
#
# The modules/rds/proxy module reads these from this instance's remote
# state to place an RDS Proxy in front of it (target_type =
# "rds-instance"). Same names as the serverless / cluster modules so a
# single proxy module can front any target_type without drift.
#--------------------------------------------------------------

output "db_subnet_ids" {
  description = "Raw private subnet IDs backing the DB subnet group. The RDS Proxy module reads these for aws_db_proxy.vpc_subnet_ids (the proxy must live in the same subnets as its target)."
  value       = aws_db_subnet_group.this.subnet_ids
}

output "vpc_id" {
  description = "VPC ID hosting the instance's DB-tier security group. The RDS Proxy module reads this to place the proxy's own security group in the same VPC."
  value       = aws_security_group.this.vpc_id
}

output "master_user_secret_kms_key_arn" {
  description = "KMS key ID encrypting the AWS-managed master user secret (= local.kms_key_arn here). The RDS Proxy module scopes its IAM role's kms:Decrypt to exactly this key. Null when var.manage_master_user_password = false. Distinct from kms_key_arn (storage key) by contract, even though this module uses one key for both."
  value       = try(aws_db_instance.this.master_user_secret[0].kms_key_id, null)
}

output "iam_database_authentication_enabled" {
  description = "Whether IAM database authentication is enabled on the instance. The RDS Proxy module reads this so its V4 precondition can reject require_iam_auth = true against a target that lacks IAM auth."
  value       = aws_db_instance.this.iam_database_authentication_enabled
}
