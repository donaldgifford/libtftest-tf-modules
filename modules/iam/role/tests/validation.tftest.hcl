# Guardrails — every validation fails closed (IMPL-0022 task 1.6).
#
# Eight rules stack on five variables here, four of them on
# trusted_role_arns alone, so each run below is constructed to leave
# exactly ONE rule violated: a passing expect_failures run proves the
# variable errored, NOT that the intended rule fired (IMPL-0020's
# lesson). Task 1.7 message-probes every one of these.

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
