#--------------------------------------------------------------
# modules/rds/cluster — Aurora provisioned cluster
#
# An Aurora provisioned cluster (aws_rds_cluster with
# engine_mode = "provisioned" + a single aws_rds_cluster_instance
# writer) for aurora-postgresql / aurora-mysql production workloads
# that need high availability and read scaling. Single-writer by
# default; readers are added out-of-band via modules/rds/read-replica.
#
# This module is the source-of-truth remote state for the
# cluster <-> read-replica composition (ADR-0001) and a valid RDS
# Proxy target (target_type = "aurora-cluster"). It forks
# modules/rds/serverless per DESIGN-0013 / IMPL-0012, dropping the
# serverlessv2_scaling_configuration block + min/max ACU inputs and
# taking a concrete var.instance_class instead of the db.serverless
# sentinel.
#--------------------------------------------------------------

#--------------------------------------------------------------
# Data sources — VPC remote state
#
# VPC remote state delivers vpc_id + private_subnet_ids per
# IMPL-0007 Q1 (reuses the existing EKS-cluster remote-state
# contract). data.aws_caller_identity.current is deliberately
# omitted — nothing in this module emits account-scoped ARNs.
#--------------------------------------------------------------

data "terraform_remote_state" "vpc" {
  backend = "s3"

  # Terragrunt multi-account shape (IMPL-0015): account-scoped key, the
  # remote-state bucket's own region, and a cross-account assume_role. The
  # session name is the fixed production literal (Q5a).
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.account_name}/${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.remote_state_bucket_region
    use_path_style = true

    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}
