# Registry policy shape (DESIGN-0030 § Policy composition).
#
# Every assertion decodes registry_policy_json and checks statement by
# statement, never by string match. Principal lists are asserted as
# LISTS on purpose: the module uses jsonencode precisely so a single
# principal never collapses to a bare string (the
# aws_iam_policy_document behaviour), and these runs pin that.

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

# Pins every default: no accounts and no statements render NO registry
# policy (an empty-statement policy is invalid in ECR), scope is managed
# and V2, and scanning is unmanaged (DESIGN-0030 OQ 3a, 6a, 7a).
run "bare_call_renders_no_policy" {
  command = plan

  variables {
    pull_repository_prefixes = []
  }

  assert {
    condition     = length(aws_ecr_registry_policy.this) == 0 && output.registry_policy_json == null
    error_message = "a bare call must render no registry policy"
  }

  assert {
    condition     = length(aws_ecr_account_setting.registry_policy_scope) == 1
    error_message = "the scope setting must be managed by default"
  }

  assert {
    condition     = aws_ecr_account_setting.registry_policy_scope[0].name == "REGISTRY_POLICY_SCOPE" && aws_ecr_account_setting.registry_policy_scope[0].value == "V2"
    error_message = "the managed setting must pin REGISTRY_POLICY_SCOPE = V2"
  }

  assert {
    condition     = length(aws_ecr_registry_scanning_configuration.this) == 0
    error_message = "scanning must be off (unmanaged) by default"
  }

  assert {
    condition     = output.registry_policy_scope == "V2" && length(output.consumer_account_ids) == 0 && output.consumer_identity_policy_json == null
    error_message = "bare-call outputs must be V2 / no accounts / no identity policy"
  }
}

run "one_plain_account" {
  command = plan

  variables {
    consumer_accounts = { "111111111111" = {} }
  }

  assert {
    condition     = length(aws_ecr_registry_policy.this) == 1
    error_message = "one account must render the registry policy"
  }

  assert {
    condition     = [for st in jsondecode(output.registry_policy_json).Statement : st.Sid] == ["ConsumerPull", "ConsumerDenyProtected"]
    error_message = "one plain account renders ConsumerPull then ConsumerDenyProtected"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[0].Principal.AWS == ["arn:aws:iam::111111111111:root"]
    error_message = "a single principal must stay a one-element LIST of the :root ARN"
  }

  assert {
    condition = jsondecode(output.registry_policy_json).Statement[0].Action == [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    error_message = "the grant must carry exactly the pull trio (OQ 4a)"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[0].Resource == ["arn:aws:ecr:us-east-1:999999999999:repository/mirror/*"]
    error_message = "the grant must cover exactly the listed prefix"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[0].Effect == "Allow" && !contains(keys(jsondecode(output.registry_policy_json).Statement[0]), "Condition")
    error_message = "a plain account's grant is an unconditioned Allow"
  }
}

run "two_plain_accounts_share_one_statement" {
  command = plan

  variables {
    consumer_accounts = {
      "222222222222" = {}
      "111111111111" = {}
    }
  }

  assert {
    condition     = length([for st in jsondecode(output.registry_policy_json).Statement : st if st.Sid == "ConsumerPull"]) == 1
    error_message = "plain accounts must share exactly one ConsumerPull statement"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[0].Principal.AWS == ["arn:aws:iam::111111111111:root", "arn:aws:iam::222222222222:root"]
    error_message = "two plain accounts render a sorted two-element principal list"
  }
}

run "one_narrowed_account" {
  command = plan

  variables {
    consumer_accounts = {
      "222222222222" = { principal_arn_patterns = ["arn:aws:iam::222222222222:role/*-node-*"] }
    }
  }

  assert {
    condition     = [for st in jsondecode(output.registry_policy_json).Statement : st.Sid] == ["ConsumerPull222222222222", "ConsumerDenyProtected"]
    error_message = "a narrowed account gets its own ConsumerPull<id> statement and no shared ConsumerPull"
  }

  assert {
    condition     = keys(jsondecode(output.registry_policy_json).Statement[0].Condition) == ["ArnLike"]
    error_message = "the narrowing condition must be exactly one ArnLike operator"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[0].Condition.ArnLike["aws:PrincipalArn"] == ["arn:aws:iam::222222222222:role/*-node-*"]
    error_message = "the narrowing must carry exactly the given patterns, as a list"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[0].Principal.AWS == ["arn:aws:iam::222222222222:root"]
    error_message = "the narrowed statement's principal is that account's :root"
  }
}

run "mixed_plain_and_narrowed" {
  command = plan

  variables {
    pull_repository_prefixes = ["mirror", "apps"]
    consumer_accounts = {
      "111111111111" = {}
      "222222222222" = { principal_arn_patterns = ["arn:aws:iam::222222222222:role/b-*", "arn:aws:iam::222222222222:role/a-*"] }
    }
  }

  assert {
    condition     = [for st in jsondecode(output.registry_policy_json).Statement : st.Sid] == ["ConsumerPull", "ConsumerPull222222222222", "ConsumerDenyProtected"]
    error_message = "mixed accounts render the shared statement, the narrowed statement, then the deny"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[0].Principal.AWS == ["arn:aws:iam::111111111111:root"]
    error_message = "the narrowed account must NOT appear in the shared ConsumerPull"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[1].Resource == ["arn:aws:ecr:us-east-1:999999999999:repository/apps/*", "arn:aws:ecr:us-east-1:999999999999:repository/mirror/*"]
    error_message = "resources must be sorted prefix ARNs"
  }
}

# The same inputs, reordered, must render byte-identical JSON.
run "reordered_inputs_render_identically" {
  command = plan

  variables {
    pull_repository_prefixes = ["apps", "mirror"]
    consumer_accounts = {
      "222222222222" = { principal_arn_patterns = ["arn:aws:iam::222222222222:role/a-*", "arn:aws:iam::222222222222:role/b-*"] }
      "111111111111" = {}
    }
  }

  assert {
    condition     = output.registry_policy_json == run.mixed_plain_and_narrowed.registry_policy_json
    error_message = "reordering prefixes, patterns or accounts must not change the rendered policy"
  }
}

#--------------------------------------------------------------
# ConsumerDenyProtected (DESIGN-0030 OQ 5b)
#--------------------------------------------------------------

run "deny_protected_names_every_account" {
  command = plan

  variables {
    protected_prefixes = ["quarantine", "staging"]
    consumer_accounts = {
      "111111111111" = {}
      "222222222222" = { principal_arn_patterns = ["arn:aws:iam::222222222222:role/*-node-*"] }
    }
  }

  assert {
    condition     = one([for st in jsondecode(output.registry_policy_json).Statement : st.Principal.AWS if st.Sid == "ConsumerDenyProtected"]) == ["arn:aws:iam::111111111111:root", "arn:aws:iam::222222222222:root"]
    error_message = "the deny must name EVERY allow-listed account, narrowed ones included"
  }

  assert {
    condition     = one([for st in jsondecode(output.registry_policy_json).Statement : st.Effect == "Deny" && st.Action == ["ecr:*"] if st.Sid == "ConsumerDenyProtected"])
    error_message = "the deny must be Effect Deny on ecr:*"
  }

  assert {
    condition = one([for st in jsondecode(output.registry_policy_json).Statement : st.Resource if st.Sid == "ConsumerDenyProtected"]) == [
      "arn:aws:ecr:us-east-1:999999999999:repository/quarantine/*",
      "arn:aws:ecr:us-east-1:999999999999:repository/staging/*",
    ]
    error_message = "the deny must cover exactly the protected prefix ARNs"
  }
}

run "deny_absent_without_protected_prefixes" {
  command = plan

  variables {
    protected_prefixes = []
    consumer_accounts  = { "111111111111" = {} }
  }

  assert {
    condition     = [for st in jsondecode(output.registry_policy_json).Statement : st.Sid] == ["ConsumerPull"]
    error_message = "with no protected prefixes the deny statement must be absent"
  }
}

run "deny_absent_without_accounts" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "Replication"
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["ecr:CreateRepository", "ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  assert {
    condition     = [for st in jsondecode(output.registry_policy_json).Statement : st.Sid] == ["Replication"]
    error_message = "with no consumer accounts only the operator statement renders: no pull grant and no deny"
  }
}

# The plan-tier half of sandbox leg P2: an operator statement granting a
# consumer repository/* cannot remove or alter the explicit deny.
run "deny_survives_overbroad_passthrough" {
  command = plan

  variables {
    consumer_accounts = { "111111111111" = {} }
    additional_policy_statements = [{
      sid        = "OverBroad"
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::111111111111:root"] }]
      actions    = ["ecr:*"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  assert {
    condition = one([for st in jsondecode(output.registry_policy_json).Statement : st if st.Sid == "ConsumerDenyProtected"]) == one([
      for st in jsondecode(run.one_plain_account.registry_policy_json).Statement : st if st.Sid == "ConsumerDenyProtected"
    ])
    error_message = "the deny must be present and unchanged alongside an over-broad pass-through"
  }
}

#--------------------------------------------------------------
# additional_policy_statements
#--------------------------------------------------------------

run "additional_statements_append_last_and_merge_conditions" {
  command = plan

  variables {
    consumer_accounts = { "111111111111" = {} }
    additional_policy_statements = [{
      sid        = "Replication"
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["ecr:CreateRepository", "ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
      conditions = [
        { test = "StringEquals", variable = "aws:SourceAccount", values = ["333333333333"] },
        { test = "StringEquals", variable = "aws:SourceRegion", values = ["us-west-2"] },
      ]
    }]
  }

  assert {
    condition     = [for st in jsondecode(output.registry_policy_json).Statement : st.Sid] == ["ConsumerPull", "ConsumerDenyProtected", "Replication"]
    error_message = "operator statements must be appended after the module's"
  }

  assert {
    condition     = keys(jsondecode(output.registry_policy_json).Statement[2].Condition) == ["StringEquals"]
    error_message = "conditions sharing a test operator must merge into one operator object"
  }

  assert {
    condition = jsondecode(output.registry_policy_json).Statement[2].Condition.StringEquals == {
      "aws:SourceAccount" = ["333333333333"]
      "aws:SourceRegion"  = ["us-west-2"]
    }
    error_message = "both condition keys must render under StringEquals"
  }

  assert {
    condition     = jsondecode(output.registry_policy_json).Statement[2].Principal == { AWS = ["arn:aws:iam::333333333333:root"] }
    error_message = "the operator statement's principals must render keyed by type"
  }
}

run "additional_statement_without_conditions_has_no_condition_key" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "Replication"
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = ["arn:aws:iam::333333333333:root"] }]
      actions    = ["ecr:ReplicateImage"]
      resources  = ["arn:aws:ecr:us-east-1:999999999999:repository/*"]
    }]
  }

  assert {
    condition     = !contains(keys(jsondecode(output.registry_policy_json).Statement[0]), "Condition")
    error_message = "a statement without conditions must not render a Condition key"
  }
}
