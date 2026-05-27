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

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
