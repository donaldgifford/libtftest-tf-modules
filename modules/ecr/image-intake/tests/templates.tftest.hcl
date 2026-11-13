# Creation templates, the template role and the intake event rule
# (DESIGN-0031 § The quarantine template, § The promoted templates,
# § The intake event rule).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "999999999999" }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }

  mock_data "aws_default_tags" {
    defaults = { tags = { ManagedBy = "terraform" } }
  }

  mock_resource "aws_iam_role" {
    override_during = plan
    defaults = {
      arn = "arn:aws:iam::999999999999:role/example-intake-ecr-templates"
    }
  }
}

variables {
  name                  = "example-intake"
  writer_principal_arns = ["arn:aws:iam::999999999999:role/sync"]
  intake_principal_arns = ["arn:aws:iam::999999999999:role/intake"]
  admin_principal_arns  = ["arn:aws:iam::999999999999:role/deploy"]
}

run "bare_call_pins_defaults" {
  command = plan

  assert {
    condition     = aws_ecr_repository_creation_template.quarantine.prefix == "quarantine" && aws_ecr_repository_creation_template.quarantine.image_tag_mutability == "MUTABLE"
    error_message = "the quarantine template defaults to prefix quarantine, MUTABLE"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.quarantine.applied_for == toset(["CREATE_ON_PUSH"]) && aws_ecr_repository_creation_template.promoted["mirror"].applied_for == toset(["CREATE_ON_PUSH"])
    error_message = "every template applies to CREATE_ON_PUSH only"
  }

  assert {
    condition     = keys(aws_ecr_repository_creation_template.promoted) == ["mirror"] && aws_ecr_repository_creation_template.promoted["mirror"].image_tag_mutability == "IMMUTABLE_WITH_EXCLUSION"
    error_message = "the default promoted prefix is mirror, IMMUTABLE_WITH_EXCLUSION"
  }

  assert {
    condition = [
      for f in aws_ecr_repository_creation_template.promoted["mirror"].image_tag_mutability_exclusion_filter : "${f.filter_type}:${f.filter}"
    ] == ["WILDCARD:sha256-*"]
    error_message = "the default exclusion is the single WILDCARD filter sha256-*"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.promoted["mirror"].lifecycle_policy == null
    error_message = "promoted templates carry no lifecycle policy (DESIGN-0031 OQ 7a)"
  }

  assert {
    condition = alltrue([
      for t in concat([aws_ecr_repository_creation_template.quarantine], values(aws_ecr_repository_creation_template.promoted)) :
      t.encryption_configuration[0].encryption_type == "AES256"
    ])
    # kms_key is Optional+Computed, so it is unknown at plan when unset;
    # the AES256 type is the assertable half.
    error_message = "encryption defaults to AES256 (DESIGN-0031 OQ 8a)"
  }

  assert {
    condition = alltrue([
      for t in concat([aws_ecr_repository_creation_template.quarantine], values(aws_ecr_repository_creation_template.promoted)) :
      t.custom_role_arn == aws_iam_role.template.arn && t.resource_tags == tomap({ ManagedBy = "terraform" })
    ])
    error_message = "every template uses the template role and carries the provider default tags as resource_tags"
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.quarantine_push) == 0 && length(aws_cloudwatch_event_target.intake) == 0 && output.intake_event_rule_arn == null
    error_message = "no event rule or target without intake_event_target"
  }

  assert {
    condition     = jsondecode(aws_ecr_repository_creation_template.quarantine.lifecycle_policy).rules[0].selection.countNumber == 7
    error_message = "quarantine retention defaults to 7 days"
  }
}

run "quarantine_lifecycle_decoded" {
  command = plan

  variables {
    quarantine_retention_days = 14
  }

  assert {
    condition     = length(jsondecode(aws_ecr_repository_creation_template.quarantine.lifecycle_policy).rules) == 1
    error_message = "the quarantine lifecycle policy has exactly one rule"
  }

  assert {
    condition = jsondecode(aws_ecr_repository_creation_template.quarantine.lifecycle_policy).rules[0].selection == {
      tagStatus   = "any"
      countType   = "sinceImagePushed"
      countUnit   = "days"
      countNumber = 14
    }
    error_message = "the rule must select EVERY image (tagStatus any) by days since push"
  }

  assert {
    condition     = jsondecode(aws_ecr_repository_creation_template.quarantine.lifecycle_policy).rules[0].action.type == "expire"
    error_message = "the rule must expire"
  }
}

run "quarantine_policy_decoded" {
  command = plan

  variables {
    # Two admins, out of order, to prove sorting and the union.
    admin_principal_arns = ["arn:aws:iam::999999999999:role/zz-break-glass", "arn:aws:iam::999999999999:role/deploy"]
  }

  assert {
    condition     = length(jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement) == 1
    error_message = "the quarantine policy has exactly one statement"
  }

  assert {
    condition = (
      jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement[0].Sid == "DenyNonPipelineImageAccess"
      && jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement[0].Effect == "Deny"
      && jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement[0].Principal == "*"
    )
    error_message = "DenyNonPipelineImageAccess must Deny Principal *"
  }

  assert {
    condition = jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement[0].Action == [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchDeleteImage",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    error_message = "the Deny must cover every pull, push and delete action"
  }

  assert {
    condition = jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement[0].Condition.ArnNotLike["aws:PrincipalArn"] == [
      "arn:aws:iam::999999999999:role/deploy",
      "arn:aws:iam::999999999999:role/intake",
      "arn:aws:iam::999999999999:role/sync",
      "arn:aws:iam::999999999999:role/zz-break-glass",
    ]
    error_message = "the exemption must be the sorted union of writers, intake and admins"
  }

  assert {
    condition     = jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement[0].Condition.BoolIfExists == { "aws:PrincipalIsAWSService" = "false" }
    error_message = "BoolIfExists must exempt AWS service principals, or the Deny blocks ECR scanning"
  }

  assert {
    condition     = keys(jsondecode(aws_ecr_repository_creation_template.quarantine.repository_policy).Statement[0].Condition) == ["ArnNotLike", "BoolIfExists"]
    error_message = "the statement must carry exactly the two condition operators"
  }
}

run "promoted_two_prefixes" {
  command = plan

  variables {
    promoted_prefixes = {
      mirror = {}
      apps   = { description = "First-party images", tag_mutability_exclusions = ["sha256-*", "*.att"] }
    }
  }

  assert {
    condition     = keys(aws_ecr_repository_creation_template.promoted) == ["apps", "mirror"]
    error_message = "each promoted prefix gets its own template"
  }

  assert {
    condition = [
      for f in aws_ecr_repository_creation_template.promoted["apps"].image_tag_mutability_exclusion_filter : f.filter
    ] == ["sha256-*", "*.att"]
    error_message = "a prefix's own exclusions must render in order"
  }

  assert {
    condition = [
      for f in aws_ecr_repository_creation_template.promoted["mirror"].image_tag_mutability_exclusion_filter : f.filter
    ] == ["sha256-*"]
    error_message = "a sibling's exclusions must not leak into another template"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.promoted["apps"].description == "First-party images" && aws_ecr_repository_creation_template.promoted["mirror"].description == "Promoted: written by intake only, never expires"
    error_message = "descriptions are per prefix, with an ASCII default"
  }

  assert {
    condition     = output.promoted_prefixes == tolist(["apps", "mirror"])
    error_message = "promoted_prefixes must be output sorted, ready for ecr/registry"
  }
}

run "promoted_policy_decoded" {
  command = plan

  assert {
    condition     = [for st in jsondecode(aws_ecr_repository_creation_template.promoted["mirror"].repository_policy).Statement : st.Sid] == ["DenyNonIntakeWrites", "DenyNonAdminPolicyChanges"]
    error_message = "the promoted policy has the two Deny statements"
  }

  assert {
    condition = alltrue([
      for st in jsondecode(aws_ecr_repository_creation_template.promoted["mirror"].repository_policy).Statement :
      st.Effect == "Deny" && st.Principal == "*" && st.Condition.BoolIfExists == { "aws:PrincipalIsAWSService" = "false" }
    ])
    error_message = "both statements Deny Principal * with the service exemption"
  }

  assert {
    condition = jsondecode(aws_ecr_repository_creation_template.promoted["mirror"].repository_policy).Statement[0].Condition.ArnNotLike["aws:PrincipalArn"] == [
      "arn:aws:iam::999999999999:role/deploy",
      "arn:aws:iam::999999999999:role/intake",
    ]
    error_message = "writes are exempt for intake and admins only, never writers"
  }

  assert {
    condition = jsondecode(aws_ecr_repository_creation_template.promoted["mirror"].repository_policy).Statement[0].Action == [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchDeleteImage",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    error_message = "DenyNonIntakeWrites covers push and delete, and no read action"
  }

  assert {
    condition     = jsondecode(aws_ecr_repository_creation_template.promoted["mirror"].repository_policy).Statement[1].Condition.ArnNotLike["aws:PrincipalArn"] == ["arn:aws:iam::999999999999:role/deploy"]
    error_message = "policy changes are exempt for admins only"
  }

  assert {
    condition = jsondecode(aws_ecr_repository_creation_template.promoted["mirror"].repository_policy).Statement[1].Action == [
      "ecr:DeleteLifecyclePolicy",
      "ecr:DeleteRepository",
      "ecr:DeleteRepositoryPolicy",
      "ecr:PutImageTagMutability",
      "ecr:PutLifecyclePolicy",
      "ecr:SetRepositoryPolicy",
    ]
    error_message = "DenyNonAdminPolicyChanges covers every loosening action"
  }
}

run "kms_encryption" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:999999999999:key/mrk-0123456789abcdef0123456789abcdef"
  }

  assert {
    condition = alltrue([
      for t in concat([aws_ecr_repository_creation_template.quarantine], values(aws_ecr_repository_creation_template.promoted)) :
      t.encryption_configuration[0].encryption_type == "KMS" && t.encryption_configuration[0].kms_key == var.kms_key_arn
    ])
    error_message = "kms_key_arn must switch every template to KMS with that key"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.template.policy).Statement[1] == { Sid = "UseRepositoryKey", Effect = "Allow", Action = ["kms:CreateGrant", "kms:DescribeKey", "kms:RetireGrant"], Resource = [var.kms_key_arn] }
    error_message = "the template role gets grant rights on exactly that key"
  }
}

run "template_role_scoped" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role.template.assume_role_policy).Statement[0] == {
      Effect    = "Allow"
      Principal = { Service = "ecr.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = "999999999999" } }
    }
    error_message = "only this account's ECR may assume the template role"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.template.policy).Statement) == 1
    error_message = "no KMS statement without kms_key_arn"
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.template.policy).Statement[0].Resource == [
      "arn:aws:ecr:us-east-1:999999999999:repository/quarantine/*",
      "arn:aws:ecr:us-east-1:999999999999:repository/mirror/*",
    ]
    error_message = "the template role is scoped to the module's prefixes"
  }
}

run "intake_event_rule" {
  command = plan

  variables {
    quarantine_prefix   = "staging/quarantine"
    promoted_prefixes   = { mirror = {} }
    intake_event_target = { arn = "arn:aws:sqs:us-east-1:999999999999:example-intake" }
  }

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.quarantine_push[0].event_pattern) == {
      source        = ["aws.ecr"]
      "detail-type" = ["ECR Image Action"]
      detail = {
        "action-type"     = ["PUSH"]
        result            = ["SUCCESS"]
        "repository-name" = [{ prefix = "staging/quarantine/" }]
      }
    }
    error_message = "the pattern must be exact, with the prefix tracking quarantine_prefix"
  }

  assert {
    condition     = output.intake_event_pattern_json == aws_cloudwatch_event_rule.quarantine_push[0].event_pattern
    error_message = "the exported pattern is the rule's pattern"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.quarantine_push[0].name == "example-intake-quarantine-push" && aws_cloudwatch_event_target.intake[0].arn == "arn:aws:sqs:us-east-1:999999999999:example-intake" && aws_cloudwatch_event_target.intake[0].role_arn == null
    error_message = "a queue target needs no role"
  }
}

run "state_machine_target_with_role_accepted" {
  command = plan

  variables {
    intake_event_target = {
      arn      = "arn:aws:states:us-east-1:999999999999:stateMachine:example-intake"
      role_arn = "arn:aws:iam::999999999999:role/example-events"
    }
  }

  assert {
    condition     = aws_cloudwatch_event_target.intake[0].role_arn == "arn:aws:iam::999999999999:role/example-events"
    error_message = "a state-machine target with a role must plan"
  }
}
