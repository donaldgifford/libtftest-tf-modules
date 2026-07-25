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

#--------------------------------------------------------------
# Pod Identity Association (the module's reason to exist)
#--------------------------------------------------------------
#
# role_arn resolution is meaningful work (mode-A vs mode-B) — kept
# inline at the resource per ADR-0001 framing rather than aliased
# through a local.
#
# The cross-variable invariant "create_role = false implies
# existing_role_arn != null" lives on the lifecycle.precondition
# below. Terraform >= 1.1 cannot reference other variables in a
# variable.validation block (1.9+ required); precondition on this
# always-present resource catches the same misconfiguration at
# plan time.

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = data.terraform_remote_state.eks.outputs.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = var.create_role ? aws_iam_role.this[0].arn : var.existing_role_arn

  tags = var.association_tags

  lifecycle {
    precondition {
      condition     = var.create_role || var.existing_role_arn != null
      error_message = "When create_role = false, existing_role_arn must be set (Mode B escape hatch needs a pre-existing Pod-Identity-trusting role)."
    }
  }
}
