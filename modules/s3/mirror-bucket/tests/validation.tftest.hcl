# Rejection suite (IMPL-0025 2.3).
#
# Per-rule verification discipline (the IMPL-0020 recipe):
# expect_failures proves only that the run errored, not which rule
# fired. Attribution for every run below:
#   - Single-rule inputs (name, ia_days, reserved-sid, core
#     coherence) fire by construction — no other rule can see the
#     trigger value.
#   - vpc_endpoint_ids carries two rules, but the triggers are
#     disjoint by construction: [] fails only non-empty (alltrue
#     over [] is true), a malformed id fails only format.
#   - Each principal list carries three rules kept disjoint by the
#     shape charset admitting *? (so a wildcard passes shape and
#     fires only the wildcard rule; a malformed value without
#     wildcards fires only shape; exact duplicates fire only dup).
# Message-probes (run without expect_failures, message read, block
# restored) were performed at build for one run per rule type; the
# probe log lives in the Phase 2 commit message.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                        = "mirror"
  vpc_endpoint_ids            = ["vpce-0123456789abcdef0"]
  policy_admin_principal_arns = ["arn:aws:iam::000000000000:role/admin"]
}

run "empty_vpc_endpoint_ids" {
  command = plan

  variables {
    vpc_endpoint_ids = []
  }

  expect_failures = [
    var.vpc_endpoint_ids,
  ]
}

run "malformed_vpce_id" {
  command = plan

  variables {
    vpc_endpoint_ids = ["subnet-12345"]
  }

  expect_failures = [
    var.vpc_endpoint_ids,
  ]
}

run "empty_policy_admin_principal_arns" {
  command = plan

  variables {
    policy_admin_principal_arns = []
  }

  expect_failures = [
    var.policy_admin_principal_arns,
  ]
}

run "malformed_break_glass_arn" {
  command = plan

  variables {
    break_glass_principal_arns = ["not-an-arn"]
  }

  expect_failures = [
    var.break_glass_principal_arns,
  ]
}

run "wildcard_break_glass_arn" {
  command = plan

  variables {
    break_glass_principal_arns = ["arn:aws:iam::000000000000:role/*"]
  }

  expect_failures = [
    var.break_glass_principal_arns,
  ]
}

run "duplicate_break_glass_arns" {
  command = plan

  variables {
    break_glass_principal_arns = [
      "arn:aws:iam::000000000000:role/a",
      "arn:aws:iam::000000000000:role/a",
    ]
  }

  expect_failures = [
    var.break_glass_principal_arns,
  ]
}

run "malformed_admin_arn" {
  command = plan

  variables {
    policy_admin_principal_arns = ["role/admin"]
  }

  expect_failures = [
    var.policy_admin_principal_arns,
  ]
}

run "wildcard_admin_arn" {
  command = plan

  variables {
    policy_admin_principal_arns = ["arn:aws:iam::000000000000:role/admin-?"]
  }

  expect_failures = [
    var.policy_admin_principal_arns,
  ]
}

run "duplicate_admin_arns" {
  command = plan

  variables {
    policy_admin_principal_arns = [
      "arn:aws:iam::000000000000:role/admin",
      "arn:aws:iam::000000000000:role/admin",
    ]
  }

  expect_failures = [
    var.policy_admin_principal_arns,
  ]
}

run "malformed_publisher_arn" {
  command = plan

  variables {
    cross_account_publisher_principal_arns = ["arn:aws:iam::123:role/publisher"]
  }

  expect_failures = [
    var.cross_account_publisher_principal_arns,
  ]
}

run "wildcard_publisher_arn" {
  command = plan

  variables {
    cross_account_publisher_principal_arns = ["arn:aws:iam::111122223333:role/*"]
  }

  expect_failures = [
    var.cross_account_publisher_principal_arns,
  ]
}

run "duplicate_publisher_arns" {
  command = plan

  variables {
    cross_account_publisher_principal_arns = [
      "arn:aws:iam::111122223333:role/publisher",
      "arn:aws:iam::111122223333:role/publisher",
    ]
  }

  expect_failures = [
    var.cross_account_publisher_principal_arns,
  ]
}

run "reserved_mirror_sid_rejected" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "DenyObjectDeletion"
      principals = { AWS = ["arn:aws:iam::000000000000:role/ops"] }
      actions    = ["s3:GetObject"]
    }]
  }

  expect_failures = [
    var.additional_policy_statements,
  ]
}

run "reserved_baseline_sid_rejected" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "DenyOutsideVpce"
      principals = { AWS = ["arn:aws:iam::000000000000:role/ops"] }
      actions    = ["s3:GetObject"]
    }]
  }

  expect_failures = [
    var.additional_policy_statements,
  ]
}

# Root-mirrored lock-coherence guard (cross-variable — the reason
# for the >= 1.9 floor; the core's identical rule would also fire,
# but only this root copy is expect_failures-addressable).
run "retention_days_without_enable" {
  command = plan

  variables {
    object_lock_retention_days = 400
  }

  expect_failures = [
    var.object_lock_retention_days,
  ]
}

run "noncurrent_version_ia_days_zero" {
  command = plan

  variables {
    noncurrent_version_ia_days = 0
  }

  expect_failures = [
    var.noncurrent_version_ia_days,
  ]
}

run "bad_name" {
  command = plan

  variables {
    name = "NOT-valid"
  }

  expect_failures = [
    var.name,
  ]
}
