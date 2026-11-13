# Identity-policy outputs (DESIGN-0031 § IAM policy outputs): the
# writer gets nothing outside quarantine, and intake gets push only on
# the promoted prefixes.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "999999999999" }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }

  mock_data "aws_default_tags" {
    defaults = { tags = {} }
  }
}

variables {
  name                  = "example-intake"
  writer_principal_arns = ["arn:aws:iam::999999999999:role/sync"]
  intake_principal_arns = ["arn:aws:iam::999999999999:role/intake"]
  admin_principal_arns  = ["arn:aws:iam::999999999999:role/deploy"]
  promoted_prefixes     = { mirror = {}, apps = {} }
}

run "writer_policy_scoped" {
  command = plan

  assert {
    condition     = [for st in jsondecode(output.writer_policy_json).Statement : st.Sid] == ["EcrAuthorizationToken", "QuarantinePush"]
    error_message = "the writer policy has the token and quarantine statements only"
  }

  assert {
    condition     = jsondecode(output.writer_policy_json).Statement[0].Action == ["ecr:GetAuthorizationToken"] && jsondecode(output.writer_policy_json).Statement[0].Resource == ["*"]
    error_message = "GetAuthorizationToken is identity-only and must be granted on *"
  }

  assert {
    condition     = jsondecode(output.writer_policy_json).Statement[1].Resource == ["arn:aws:ecr:us-east-1:999999999999:repository/quarantine/*"]
    error_message = "the writer's grants must cover the quarantine prefix and nothing else"
  }

  assert {
    condition = jsondecode(output.writer_policy_json).Statement[1].Action == [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:CreateRepository",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    error_message = "the writer gets push, create-on-push and the manifest read its idempotency check needs"
  }
}

run "intake_policy_scoped" {
  command = plan

  assert {
    condition     = [for st in jsondecode(output.intake_policy_json).Statement : st.Sid] == ["EcrAuthorizationToken", "QuarantineRead", "PromotedWrite"]
    error_message = "the intake policy has token, quarantine-read and promoted-write statements"
  }

  assert {
    condition     = jsondecode(output.intake_policy_json).Statement[1].Resource == ["arn:aws:ecr:us-east-1:999999999999:repository/quarantine/*"]
    error_message = "QuarantineRead is scoped to quarantine"
  }

  assert {
    condition = length(setintersection(
      toset(jsondecode(output.intake_policy_json).Statement[1].Action),
      toset(["ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:BatchDeleteImage", "ecr:CreateRepository"]),
    )) == 0
    error_message = "intake must have no write action on quarantine"
  }

  assert {
    condition = jsondecode(output.intake_policy_json).Statement[2].Resource == [
      "arn:aws:ecr:us-east-1:999999999999:repository/apps/*",
      "arn:aws:ecr:us-east-1:999999999999:repository/mirror/*",
    ]
    error_message = "PromotedWrite covers exactly the promoted prefixes"
  }

  assert {
    condition     = contains(jsondecode(output.intake_policy_json).Statement[2].Action, "ecr:PutImage") && contains(jsondecode(output.intake_policy_json).Statement[2].Action, "ecr:CreateRepository")
    error_message = "intake can push and create-on-push in promoted prefixes"
  }

  assert {
    condition     = !contains(jsondecode(output.intake_policy_json).Statement[2].Action, "ecr:BatchDeleteImage")
    error_message = "intake cannot delete promoted images"
  }
}

run "no_grant_reaches_outside_the_prefixes" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [output.writer_policy_json, output.intake_policy_json] : [
        for st in jsondecode(doc).Statement : [
          for r in st.Resource :
          r == "*" ? st.Action == ["ecr:GetAuthorizationToken"] : contains([
            "arn:aws:ecr:us-east-1:999999999999:repository/quarantine/*",
            "arn:aws:ecr:us-east-1:999999999999:repository/apps/*",
            "arn:aws:ecr:us-east-1:999999999999:repository/mirror/*",
          ], r)
        ]
      ]
    ]))
    error_message = "every resource is a module prefix, and * carries only GetAuthorizationToken"
  }

  assert {
    condition     = output.quarantine_prefix == "quarantine"
    error_message = "quarantine_prefix is exported"
  }
}

run "grammar_edge_values_accepted" {
  command = plan

  variables {
    name                      = "Example_intake-0123456789012345678901234"
    quarantine_prefix         = "q.0_a-b/c"
    quarantine_retention_days = 30
    promoted_prefixes = {
      "mirror/registry.k8s.io" = { tag_mutability_exclusions = ["sha256-*", "*.sig", "*.att", "v1.2_3-rc", "a"] }
    }
  }

  assert {
    condition     = output.promoted_prefixes == tolist(["mirror/registry.k8s.io"]) && output.quarantine_prefix == "q.0_a-b/c"
    error_message = "valid grammar edge values must pass every regex rule"
  }
}

run "retention_lower_bound_accepted" {
  command = plan

  variables {
    quarantine_retention_days = 1
  }

  assert {
    condition     = output.quarantine_prefix == var.quarantine_prefix
    error_message = "1 day is a valid retention"
  }
}
