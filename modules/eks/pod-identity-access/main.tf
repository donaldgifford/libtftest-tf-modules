#--------------------------------------------------------------
# Pod Identity Access Module — entrypoint
#--------------------------------------------------------------
#
# Binds a Kubernetes service account to AWS credentials via an
# EKS Pod Identity Association per DESIGN-0004 / ADR-0004. This
# module is instantiated many times per cluster — one per
# (namespace, service_account) pair.
#
# Mode A (default): the module creates a Pod-Identity-trusting
# IAM role in iam.tf with caller-supplied managed/customer/
# inline policies, and the association binds to it.
#
# Mode B (escape hatch): the caller passes existing_role_arn;
# the module creates only the association.
#
# Phase 5 will land aws_eks_pod_identity_association.this here.

#--------------------------------------------------------------
# Cluster remote state (ADR-0001)
#--------------------------------------------------------------
#
# use_path_style = true keeps S3 addressing as bucket-in-path so
# the data source works against any S3 endpoint (production,
# LocalStack, etc.) without virtual-host DNS dependence.

# tflint-ignore: terraform_unused_declarations  # consumed by aws_eks_pod_identity_association.this in Phase 5
data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
