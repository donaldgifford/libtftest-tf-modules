#--------------------------------------------------------------
# Cluster remote state (ADR-0001 / ADR-0020)
#--------------------------------------------------------------
#
# The fourth eks-state consumer, identical in read shape to addons and
# pod-identity-access. Its own stack — and therefore its own plan
# cadence and blast radius — is the whole point of the module
# (DESIGN-0024 part 1): access entries are the highest-churn
# cluster-adjacent surface, and none of that churn should plan, lock,
# or risk the stack that owns the control plane, the KMS key, and the
# node security group.
#
# use_path_style = true keeps S3 addressing as bucket-in-path so the
# data source works against any S3 endpoint (production, LocalStack)
# without virtual-host DNS dependence.

data "terraform_remote_state" "eks" {
  backend = "s3"

  # Terragrunt multi-account shape (IMPL-0015): account-scoped key, the
  # remote-state bucket's own region, and a cross-account assume_role. The
  # session name is the fixed production literal (Q5a).
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.account_name}/${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.remote_state_bucket_region
    use_path_style = true

    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}
