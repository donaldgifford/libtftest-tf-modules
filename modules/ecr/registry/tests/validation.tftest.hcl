# Fail-closed rejections (DESIGN-0030 / IMPL-0027 Phase 2).
#
# VERIFICATION DISCIPLINE. `expect_failures` asserts only that the named
# object errored, NOT which of its rules fired. Six validations stack on
# var.consumer_accounts and six on var.additional_policy_statements, so
# any run below could pass off a neighbouring rule and look identically
# green. Every rejection was therefore verified by MESSAGE PROBE: the
# case run in isolation, without expect_failures, with the real error
# read. The probe transcript lives in IMPL-0027 Phase 2.
#
# The positive runs at the bottom are load-bearing (the IMPL-0024 RE2
# lesson): a regex rule that rejects EVERYTHING still passes every fail
# case, so each regex-shaped rule also has a run it must let through.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "999999999999" }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

variables {
  pull_repository_prefixes = ["mirror"]
}

run "account_id_malformed" {
  command = plan

  variables {
    consumer_accounts = { "12345" = {} }
  }

  expect_failures = [var.consumer_accounts]
}

run "pattern_names_another_account" {
  command = plan

  variables {
    consumer_accounts = { "111111111111" = { principal_arn_patterns = ["arn:aws:iam::222222222222:role/x"] } }
  }

  expect_failures = [var.consumer_accounts]
}

run "pattern_with_whitespace" {
  command = plan

  variables {
    consumer_accounts = { "111111111111" = { principal_arn_patterns = ["arn:aws:iam::111111111111:role/ x"] } }
  }

  expect_failures = [var.consumer_accounts]
}

run "pattern_equivalent_to_no_narrowing" {
  command = plan

  variables {
    consumer_accounts = { "111111111111" = { principal_arn_patterns = ["arn:aws:iam::111111111111:*"] } }
  }

  expect_failures = [var.consumer_accounts]
}

run "duplicate_patterns" {
  command = plan

  variables {
    consumer_accounts = { "111111111111" = { principal_arn_patterns = ["arn:aws:iam::111111111111:role/a", "arn:aws:iam::111111111111:role/a"] } }
  }

  expect_failures = [var.consumer_accounts]
}

run "accounts_without_prefixes" {
  command = plan

  variables {
    pull_repository_prefixes = []
    consumer_accounts        = { "111111111111" = {} }
  }

  expect_failures = [var.consumer_accounts]
}

run "prefix_with_wildcard" {
  command = plan

  variables {
    pull_repository_prefixes = ["mirror/*"]
  }

  expect_failures = [var.pull_repository_prefixes]
}

run "prefix_uppercase" {
  command = plan

  variables {
    pull_repository_prefixes = ["Mirror"]
  }

  expect_failures = [var.pull_repository_prefixes]
}

run "prefix_leading_slash" {
  command = plan

  variables {
    pull_repository_prefixes = ["/mirror"]
  }

  expect_failures = [var.pull_repository_prefixes]
}

run "prefix_duplicate" {
  command = plan

  variables {
    pull_repository_prefixes = ["mirror", "mirror"]
  }

  expect_failures = [var.pull_repository_prefixes]
}

run "prefix_equals_protected" {
  command = plan

  variables {
    pull_repository_prefixes = ["quarantine"]
  }

  expect_failures = [var.pull_repository_prefixes]
}

run "prefix_inside_protected" {
  command = plan

  variables {
    pull_repository_prefixes = ["quarantine/mirror"]
  }

  expect_failures = [var.pull_repository_prefixes]
}

run "prefix_contains_protected" {
  command = plan

  variables {
    protected_prefixes       = ["quarantine/mirror"]
    pull_repository_prefixes = ["quarantine"]
  }

  expect_failures = [var.pull_repository_prefixes]
}

run "protected_bad_grammar" {
  command = plan

  variables {
    protected_prefixes = ["Quarantine/"]
  }

  expect_failures = [var.protected_prefixes]
}

run "protected_duplicate" {
  command = plan

  variables {
    protected_prefixes = ["quarantine", "quarantine"]
  }

  expect_failures = [var.protected_prefixes]
}

run "sid_not_alphanumeric" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "Bad-Sid"
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
}

run "sid_duplicate" {
  command = plan

  variables {
    additional_policy_statements = [
      {
        sid        = "Replication"
        effect     = "Allow"
        principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
        actions    = ["ecr:ReplicateImage"]
        resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
      },
      {
        sid        = "Replication"
        effect     = "Allow"
        principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
        actions    = ["ecr:ReplicateImage"]
        resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
      },
    ]
  }

  expect_failures = [var.additional_policy_statements]
}

run "sid_reserved_prefix" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "ConsumerExtra"
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
}

run "effect_not_enum" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "Replication"
      effect     = "allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
}

run "action_not_ecr" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "Replication"
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["s3:GetObject"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
}

run "principal_type_not_allowed" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "Replication"
      effect     = "Allow"
      principals = [{ type = "Federated", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
}

run "scan_type_unknown" {
  command = plan

  variables {
    scanning = { scan_type = "FULL", rules = [{ scan_frequency = "SCAN_ON_PUSH", filters = ["*"] }] }
  }

  expect_failures = [var.scanning]
}

run "basic_with_continuous_scan" {
  command = plan

  variables {
    scanning = { scan_type = "BASIC", rules = [{ scan_frequency = "CONTINUOUS_SCAN", filters = ["*"] }] }
  }

  expect_failures = [var.scanning]
}

run "enhanced_with_manual" {
  command = plan

  variables {
    scanning = { scan_type = "ENHANCED", rules = [{ scan_frequency = "MANUAL", filters = ["*"] }] }
  }

  expect_failures = [var.scanning]
}

run "scan_rule_without_filters" {
  command = plan

  variables {
    scanning = { scan_type = "BASIC", rules = [{ scan_frequency = "SCAN_ON_PUSH", filters = [] }] }
  }

  expect_failures = [var.scanning]
}

run "self_account_rejected" {
  command = plan

  variables {
    consumer_accounts = { "999999999999" = {} }
  }

  expect_failures = [aws_ecr_registry_policy.this]
}

#--------------------------------------------------------------
# Positive runs: each regex-shaped rule must let a valid value through.
#--------------------------------------------------------------

run "grammar_edge_values_accepted" {
  command = plan

  variables {
    pull_repository_prefixes = ["mirror/registry.k8s.io/ingress-nginx", "first-party_apps", "a.b-c"]
    protected_prefixes       = ["quarantine", "staging-area"]
    consumer_accounts = {
      "012345678901" = { principal_arn_patterns = ["arn:aws:iam::012345678901:role/eks/*-node-*", "arn:aws:iam::012345678901:user/ci"] }
    }
    additional_policy_statements = [{
      sid        = "Replication2"
      effect     = "Deny"
      principals = [{ type = "Service", identifiers = ["replication.ecr.amazonaws.com"] }]
      actions    = ["ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  assert {
    condition     = length(aws_ecr_registry_policy.this) == 1
    error_message = "valid edge values (dotted/underscored/nested prefixes, a leading-zero account id, path-bearing patterns, a digit-bearing sid, a Service principal) must all be accepted"
  }
}

run "basic_manual_accepted" {
  command = plan

  variables {
    scanning = { scan_type = "BASIC", rules = [{ scan_frequency = "MANUAL", filters = ["mirror/*"] }] }
  }

  assert {
    condition     = length(aws_ecr_registry_scanning_configuration.this) == 1
    error_message = "BASIC + MANUAL must be accepted"
  }
}

run "enhanced_on_push_accepted" {
  command = plan

  variables {
    scanning = { scan_type = "ENHANCED", rules = [{ scan_frequency = "SCAN_ON_PUSH", filters = ["mirror/*"] }] }
  }

  assert {
    condition     = length(aws_ecr_registry_scanning_configuration.this) == 1
    error_message = "ENHANCED + SCAN_ON_PUSH must be accepted"
  }
}
