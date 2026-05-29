#--------------------------------------------------------------
# Computed locals
#--------------------------------------------------------------

locals {
  # KMS key ARN — BYO (var.kms_key_arn != null) OR module-managed
  # (aws_kms_key.this[0] from kms.tf, Phase 3). try() keeps the
  # plan valid before the BYO short-circuits the count gate and
  # after the managed key's ARN is apply-time known. Same coalesce-
  # with-try pattern used in modules/rds/serverless/locals.tf and
  # modules/ecr/org-registry/locals.tf.
  kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))

  kms_alias_name = "alias/${var.identifier_prefix}-efs"

  # NFS TCP port. EFS exposes one port; no engine-port map needed
  # unlike RDS. Referenced by network.tf for the from_nodes +
  # from_extra ingress rules.
  nfs_port = 2049
}
