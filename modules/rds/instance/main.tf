# RDS instance module (modules/rds/instance)
#
# A single, non-clustered aws_db_instance for postgres / mysql workloads
# that don't need Aurora (DESIGN-0012 / IMPL-0011). Forks the shipped
# modules/rds/serverless scaffolding: VPC remote state, managed-or-BYO
# KMS, granular SG rules, AWS-managed master password, static
# parameter-family lookup, and the validation-split doctrine
# (single-variable -> variable.validation; cross-variable ->
# lifecycle.precondition). Emits the seven proxy-composition outputs so
# it is a valid target_type = "rds-instance" for modules/rds/proxy.

#--------------------------------------------------------------
# Data sources — VPC remote state
#
# VPC remote state delivers vpc_id + private_subnet_ids per
# IMPL-0007 Q1 (reuses the existing EKS-cluster remote-state
# contract — NOT database_subnet_ids). data.aws_caller_identity.current
# is deliberately omitted — nothing in this module emits account-scoped
# ARNs.
#--------------------------------------------------------------

data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
