# Scope setting, scanning and the consumer-contract outputs
# (DESIGN-0030 § Registry policy scope, § Scanning, § Outputs).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "999999999999" }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

variables {
  pull_repository_prefixes = ["mirror", "apps"]
  consumer_accounts        = { "111111111111" = {} }
}

run "scope_unmanaged" {
  command = plan

  variables {
    manage_registry_policy_scope = false
  }

  assert {
    condition     = length(aws_ecr_account_setting.registry_policy_scope) == 0 && output.registry_policy_scope == null
    error_message = "manage_registry_policy_scope = false must create no setting and output null"
  }

  assert {
    condition     = length(aws_ecr_registry_policy.this) == 1
    error_message = "the policy still renders when the scope is managed elsewhere"
  }
}

run "scanning_basic_on_push" {
  command = plan

  variables {
    scanning = {
      scan_type = "BASIC"
      rules     = [{ scan_frequency = "SCAN_ON_PUSH", filters = ["quarantine/*", "mirror/*"] }]
    }
  }

  assert {
    condition     = length(aws_ecr_registry_scanning_configuration.this) == 1 && aws_ecr_registry_scanning_configuration.this[0].scan_type == "BASIC"
    error_message = "a non-null scanning input must create the BASIC scanning configuration"
  }

  assert {
    condition     = [for r in aws_ecr_registry_scanning_configuration.this[0].rule : r.scan_frequency] == ["SCAN_ON_PUSH"]
    error_message = "the rule must carry its scan frequency"
  }

  assert {
    condition = toset(flatten([
      for r in aws_ecr_registry_scanning_configuration.this[0].rule : [for f in r.repository_filter : "${f.filter_type}:${f.filter}"]
    ])) == toset(["WILDCARD:quarantine/*", "WILDCARD:mirror/*"])
    error_message = "each filter must render as a WILDCARD repository_filter"
  }
}

run "scanning_enhanced_continuous" {
  command = plan

  variables {
    scanning = {
      scan_type = "ENHANCED"
      rules     = [{ scan_frequency = "CONTINUOUS_SCAN", filters = ["mirror/*"] }]
    }
  }

  assert {
    condition     = aws_ecr_registry_scanning_configuration.this[0].scan_type == "ENHANCED"
    error_message = "ENHANCED + CONTINUOUS_SCAN must be accepted"
  }
}

run "consumer_contract_outputs" {
  command = plan

  assert {
    condition     = output.registry_id == "999999999999" && output.registry_url == "999999999999.dkr.ecr.us-east-1.amazonaws.com"
    error_message = "registry_id / registry_url must compose from the provider's account and region"
  }

  assert {
    condition     = output.consumer_account_ids == tolist(["111111111111"]) && output.pull_repository_prefixes == tolist(["apps", "mirror"])
    error_message = "ids and prefixes must be output sorted"
  }

  assert {
    condition     = output.pull_repository_arns == ["arn:aws:ecr:us-east-1:999999999999:repository/apps/*", "arn:aws:ecr:us-east-1:999999999999:repository/mirror/*"]
    error_message = "pull_repository_arns must be the rendered prefix ARNs"
  }

  assert {
    condition     = [for st in jsondecode(output.consumer_identity_policy_json).Statement : st.Sid] == ["EcrAuthorizationToken", "RegistryPull"]
    error_message = "the consumer identity policy has the token statement and the pull statement"
  }

  assert {
    condition     = jsondecode(output.consumer_identity_policy_json).Statement[0].Action == ["ecr:GetAuthorizationToken"] && jsondecode(output.consumer_identity_policy_json).Statement[0].Resource == ["*"]
    error_message = "GetAuthorizationToken is identity-only and must be granted on *"
  }

  assert {
    condition     = jsondecode(output.consumer_identity_policy_json).Statement[1].Resource == output.pull_repository_arns
    error_message = "the consumer pull statement must cover exactly the shared prefixes"
  }
}
