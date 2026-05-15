#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------
#
# Cross-module composition per ADR-0001: cluster + VPC state files
# are the last-known-good ground truth, read at the use site rather
# than re-aliased through locals.
#
# use_path_style = true keeps S3 addressing as bucket-in-path so the
# data source works against any S3 endpoint (production, LocalStack,
# etc.) without virtual-host DNS dependence. Matches the cluster
# module's drive-by fix.

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}

data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
