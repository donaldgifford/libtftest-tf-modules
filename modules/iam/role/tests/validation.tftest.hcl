# Guardrails — every validation fails closed (IMPL-0022 task 1.6).
#
# Twelve rules stack on seven variables here, five of them on
# trusted_role_arns alone, so each run below is constructed to leave
# exactly ONE rule violated: a passing expect_failures run proves the
# variable errored, NOT that the intended rule fired (IMPL-0020's
# lesson). Task 1.7 message-probes every one of these.
#
# The last five runs are the security-review regressions (IMPL-0022
# task 4.6) — each one is a call the module ACCEPTED before the
# review, verified by re-running these inputs against the pre-fix
# module and watching all five plan green.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name              = "guardrail-role"
  trusted_role_arns = ["arn:aws:iam::000000000000:role/atlantis-pod-identity"]
}

# --- trusted_role_arns: the fail-closed trust surface ---

run "empty_trust_list_rejected" {
  command = plan

  variables {
    trusted_role_arns = []
  }

  expect_failures = [var.trusted_role_arns]
}

# A wildcard principal is the fail-open this typed surface exists to
# prevent. The entry is otherwise ARN-shaped, so only the wildcard
# rule can catch it.
run "wildcard_arn_rejected" {
  command = plan

  variables {
    trusted_role_arns = ["arn:aws:iam::000000000000:role/*"]
  }

  expect_failures = [var.trusted_role_arns]
}

run "malformed_arn_rejected" {
  command = plan

  variables {
    trusted_role_arns = ["arn:aws:iam::12345:role/too-few-account-digits"]
  }

  expect_failures = [var.trusted_role_arns]
}

# Service principals belong to the resource-owning modules; passing
# one here must fail rather than silently composing a trust policy
# nobody reviewed for it (DESIGN-0025 OQ 1a / Non-Goals).
run "service_principal_rejected" {
  command = plan

  variables {
    trusted_role_arns = ["pods.eks.amazonaws.com"]
  }

  expect_failures = [var.trusted_role_arns]
}

# OQ 2a: IAM dedupes principals at policy save, so this is an audit
# rule — a repeated ARN misstates the principal count reviewers read.
run "duplicate_principal_rejected" {
  command = plan

  variables {
    trusted_role_arns = [
      "arn:aws:iam::000000000000:role/atlantis-pod-identity",
      "arn:aws:iam::000000000000:role/atlantis-pod-identity",
    ]
  }

  expect_failures = [var.trusted_role_arns]
}

# --- name / path / session duration ---

run "name_bad_charset_rejected" {
  command = plan

  variables {
    name = "has spaces"
  }

  expect_failures = [var.name]
}

run "name_too_long_rejected" {
  command = plan

  variables {
    # 65 chars — one past the IAM role-name limit, charset-valid.
    name = "aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffffggggg"
  }

  expect_failures = [var.name]
}

run "path_without_trailing_slash_rejected" {
  command = plan

  variables {
    path = "/platform"
  }

  expect_failures = [var.path]
}

run "session_duration_too_long_rejected" {
  command = plan

  variables {
    max_session_duration = 43201
  }

  expect_failures = [var.max_session_duration]
}

run "session_duration_too_short_rejected" {
  command = plan

  variables {
    max_session_duration = 900
  }

  expect_failures = [var.max_session_duration]
}

# --- inline_policies (OQ 1a) ---

# Malformed JSON is a guaranteed apply-time MalformedPolicyDocument;
# the validation moves it to plan.
run "malformed_inline_json_rejected" {
  command = plan

  variables {
    inline_policies = {
      broken = "{not valid json"
    }
  }

  expect_failures = [var.inline_policies]
}

# --- security-review regressions (IMPL-0022 task 4.6) ---

# F1: the provider omits permissions_boundary on create when it is ""
# and DELETES the boundary on update, so "" plans as "bounded" and
# applies as unbounded. The realistic source is a live-repo
# try(dependency.x.outputs.arn, "") or a lookup miss.
run "empty_string_permissions_boundary_rejected" {
  command = plan

  variables {
    permissions_boundary = ""
  }

  expect_failures = [var.permissions_boundary]
}

# F3a: ".+$" matches a trailing space, so a padded ARN reached
# Principal.AWS verbatim and resolved to no principal at all.
run "padded_trust_arn_rejected" {
  command = plan

  variables {
    trusted_role_arns = ["arn:aws:iam::000000000000:role/atlantis-pod-identity "]
  }

  expect_failures = [var.trusted_role_arns]
}

# F3b: IAM role names are account-unique CASE-INSENSITIVELY, so these
# two spellings are one principal. Raw distinct() saw two.
run "case_variant_duplicate_principal_rejected" {
  command = plan

  variables {
    trusted_role_arns = [
      "arn:aws:iam::000000000000:role/atlantis-pod-identity",
      "arn:aws:iam::000000000000:role/Atlantis-Pod-Identity",
    ]
  }

  expect_failures = [var.trusted_role_arns]
}

# F3c: the same role's path-bearing and path-stripped spellings — the
# exact evasion IMPL-0020's collision guard normalizes against, and
# the one var.path's own description warns about.
run "path_variant_duplicate_principal_rejected" {
  command = plan

  variables {
    trusted_role_arns = [
      "arn:aws:iam::000000000000:role/platform/deploy-tf",
      "arn:aws:iam::000000000000:role/deploy-tf",
    ]
  }

  expect_failures = [var.trusted_role_arns]
}

# F2/F6: listing one ARN in BOTH channels minted two attachment
# resources over one real (idempotent) attachment, so dropping it from
# one channel detached the policy while the other still declared it —
# a "1 to destroy" plan that silently re-grants on the next apply. The
# typed channel partition makes that state unrepresentable: this ARN
# is AWS-managed, so the customer channel now rejects it.
run "aws_managed_arn_in_customer_channel_rejected" {
  command = plan

  variables {
    managed_policy_arns          = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    customer_managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  }

  expect_failures = [var.customer_managed_policy_arns]
}

run "customer_arn_in_aws_managed_channel_rejected" {
  command = plan

  variables {
    managed_policy_arns = ["arn:aws:iam::000000000000:policy/platform-deploy"]
  }

  expect_failures = [var.managed_policy_arns]
}

# --- trust conditions (DESIGN-0027 Part A) ---

run "malformed_org_id_rejected" {
  command = plan

  variables {
    require_org_ids = ["org-a1b2c3d4e5"]
  }

  expect_failures = [var.require_org_ids]
}

# The F1 shape, pre-empted: an empty string would render
# "aws:PrincipalOrgID": [""] — a condition nobody can satisfy. It
# fails closed, so it is a lockout rather than a hole, but an
# unexplained one.
run "empty_string_org_id_rejected" {
  command = plan

  variables {
    require_org_ids = [""]
  }

  expect_failures = [var.require_org_ids]
}

# An audit rule, like duplicate principals: the condition should
# state each organization exactly once.
run "duplicate_org_id_rejected" {
  command = plan

  variables {
    require_org_ids = ["o-a1b2c3d4e5", "o-a1b2c3d4e5"]
  }

  expect_failures = [var.require_org_ids]
}

run "external_id_bad_charset_rejected" {
  command = plan

  variables {
    external_id = "has spaces and \"quotes\""
  }

  expect_failures = [var.external_id]
}

# Length is its own rule because Go's RE2 caps a bounded repeat at
# 1000, making the obvious "{2,1224}" charset+length regex INVALID —
# can() would swallow that and reject everything. See variables.tf.
run "external_id_too_short_rejected" {
  command = plan

  variables {
    external_id = "x"
  }

  expect_failures = [var.external_id]
}
