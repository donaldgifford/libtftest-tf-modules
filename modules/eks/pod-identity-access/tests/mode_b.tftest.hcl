# Mode B (escape hatch) plan-time invariants.
#
# create_role = false + caller-supplied existing_role_arn produces zero
# IAM resources and exactly one Pod Identity Association whose role_arn
# echoes the input.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  remote_state_bucket = "stub-bucket"
  region              = "us-east-1"
  cluster_name        = "libtftest-cluster"
  namespace           = "kube-system"
  service_account     = "preexisting-sa"
  create_role         = false
  existing_role_arn   = "arn:aws:iam::123456789012:role/preexisting"
  # Policy inputs intentionally non-empty to prove gating: var.create_role
  # = false must suppress ALL Mode A resources regardless of the policy
  # variables' contents.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
  ]
  inline_policies = {
    nope = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

run "plan_mode_b" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  # Mode A resources fully suppressed.
  assert {
    condition     = length(aws_iam_role.this) == 0
    error_message = "Mode B must create zero IAM roles"
  }
  assert {
    condition     = length(data.aws_iam_policy_document.pod_identity_trust) == 0
    error_message = "Mode B must not render the trust policy data source"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 0 && length(aws_iam_role_policy_attachment.customer) == 0
    error_message = "Mode B must create zero policy attachments (gating works even with non-empty policy vars)"
  }
  assert {
    condition     = length(aws_iam_role_policy.inline) == 0
    error_message = "Mode B must create zero inline policies (gating works even with non-empty inline_policies)"
  }

  # The Pod Identity Association — role_arn echoes the input.
  assert {
    condition     = aws_eks_pod_identity_association.this.role_arn == "arn:aws:iam::123456789012:role/preexisting"
    error_message = "Mode B association's role_arn must equal var.existing_role_arn"
  }
  assert {
    condition     = aws_eks_pod_identity_association.this.service_account == "preexisting-sa"
    error_message = "Mode B association still binds to var.service_account"
  }
}
