# Policy-channel guardrails — DESIGN-0027 Part B (IMPL-0024 task 2.5).
#
# These four rules are mirrored VERBATIM from iam/role, where the
# IMPL-0022 security review added them after finding each one live.
# This module carried the same four-input policy surface with no
# validation at all, so it carried the same defects:
#
#   F1  permissions_boundary = "" yields an UNBOUNDED role — the
#       provider omits the argument on create and DELETES the boundary
#       on update, so "" reads as "bounded" in a plan.
#   F2  the same ARN in both channels made revocation a silent no-op
#       (idempotent AttachRolePolicy, two resources over one real
#       attachment) — closed structurally by the channel partition.
#   F6  neither channel enforced the split both READMEs advertise.
#
# Each run leaves exactly ONE rule violated; task 2.5 message-probes
# every one, because expect_failures proves only that the variable
# errored, not which rule fired (IMPL-0020).

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
  service_account     = "guardrail-sa"
}

run "empty_string_permissions_boundary_rejected" {
  command = plan

  # A variable-validation failure does NOT short-circuit data-source
  # evaluation, so without this the remote-state read fires and the
  # run dies on real credentials instead of the rule under test.
  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  variables {
    permissions_boundary = ""
  }

  expect_failures = [var.permissions_boundary]
}

# The F2 pair: one ARN in both channels is now unrepresentable,
# because the account field ("aws" vs 12 digits) is mutually
# exclusive between the two rules.
run "aws_managed_arn_in_customer_channel_rejected" {
  command = plan

  # A variable-validation failure does NOT short-circuit data-source
  # evaluation, so without this the remote-state read fires and the
  # run dies on real credentials instead of the rule under test.
  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  variables {
    managed_policy_arns          = ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
    customer_managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
  }

  expect_failures = [var.customer_managed_policy_arns]
}

run "customer_arn_in_aws_managed_channel_rejected" {
  command = plan

  # A variable-validation failure does NOT short-circuit data-source
  # evaluation, so without this the remote-state read fires and the
  # run dies on real credentials instead of the rule under test.
  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  variables {
    managed_policy_arns = ["arn:aws:iam::123456789012:policy/team-owned"]
  }

  expect_failures = [var.managed_policy_arns]
}

run "malformed_inline_json_rejected" {
  command = plan

  # A variable-validation failure does NOT short-circuit data-source
  # evaluation, so without this the remote-state read fires and the
  # run dies on real credentials instead of the rule under test.
  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  variables {
    inline_policies = {
      broken = "{not valid json"
    }
  }

  expect_failures = [var.inline_policies]
}
