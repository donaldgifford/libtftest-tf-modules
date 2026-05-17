# Mode B precondition negative.
#
# create_role = false + existing_role_arn = null must fail at plan
# time via the lifecycle.precondition on
# aws_eks_pod_identity_association.this.
#
# expect_failures targets the resource (not the variable) because the
# invariant is enforced via lifecycle.precondition rather than
# variable.validation — terraform >= 1.1 cannot cross-reference vars
# in variable.validation, see existing_role_arn's description.

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
  service_account     = "broken-config"
  create_role         = false
  existing_role_arn   = null
}

run "negative_mode_b_missing_arn" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  expect_failures = [aws_eks_pod_identity_association.this]
}
