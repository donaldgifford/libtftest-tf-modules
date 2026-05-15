#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------
#
# Cross-module composition per ADR-0001: the cluster state file
# is the last-known-good ground truth for cluster_name, K8s
# version, and OIDC issuer. Read at the use site rather than
# re-aliased through locals.
#
# use_path_style = true keeps S3 addressing as bucket-in-path
# so the data source works against any S3 endpoint (production,
# LocalStack, etc.) without virtual-host DNS dependence.

# tflint-ignore: terraform_unused_declarations  # consumed in a later IMPL-0003 phase
data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
