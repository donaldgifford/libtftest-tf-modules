# The collision guard's degrade path — IMPL-0020 Phase 4, task 4.5.
#
# sso_principal_arn is an ADDITIVE cluster output (DESIGN-0024 part 2),
# so any cluster stack that has not re-applied since will have state
# without it. Reading a missing output is a hard error in Terraform, so
# the guard's read is try()-wrapped: a stale cluster state must degrade
# to no-guard, never break every plan in this module.
#
# The operator-facing consequence is in the README: re-apply the
# cluster stack to arm the guard.

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
}

# A pre-DESIGN-0024 cluster state: no sso_principal_arn key at all.
override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_name              = "libtftest-cluster"
      cluster_version           = "1.31"
      cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
      cluster_ca_data           = "Y2EtZGF0YQ=="
      cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
      cluster_security_group_id = "sg-cluster-stub"
      node_security_group_id    = "sg-node-stub"
      kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
    }
  }
}

run "stale_state_degrades_to_no_guard" {
  command = plan

  variables {
    access_entries = {
      # Deliberately the SSO-shaped principal that WOULD collide if the
      # guard were armed. Against stale state it must plan, not error.
      sso_admin = {
        principal_arn = "arn:aws:iam::000000000000:role/AWSReservedSSO_Admin_abcdef1234567890"
      }
    }
  }

  assert {
    condition     = aws_eks_access_entry.this["sso_admin"].principal_arn == "arn:aws:iam::000000000000:role/AWSReservedSSO_Admin_abcdef1234567890"
    error_message = "a cluster state predating the sso_principal_arn output must degrade to no-guard, not fail the plan"
  }
}
