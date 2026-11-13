# Fail-closed rejections (DESIGN-0031 / IMPL-0027 Phase 4).
#
# VERIFICATION DISCIPLINE: expect_failures proves the variable errored,
# not which rule fired, and five or more rules stack on each principal
# list and on promoted_prefixes. Every rejection was message-probed in
# isolation (IMPL-0027 Phase 4 transcript). Positive runs live in
# templates.tftest.hcl and policy_outputs.tftest.hcl.
#
# Padded-ARN runs use a TRAILING space: a leading one would also fail
# the ARN regex, and two rules would answer for one run.

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
}

run "name_bad_charset" {
  command = plan

  variables {
    name = "example intake"
  }

  expect_failures = [var.name]
}

run "name_too_long" {
  command = plan

  variables {
    name = "example-intake-01234567890123456789012345"
  }

  expect_failures = [var.name]
}

run "quarantine_prefix_bad_grammar" {
  command = plan

  variables {
    quarantine_prefix = "Quarantine"
  }

  expect_failures = [var.quarantine_prefix]
}

run "retention_zero" {
  command = plan

  variables {
    quarantine_retention_days = 0
  }

  expect_failures = [var.quarantine_retention_days]
}

run "retention_over_thirty" {
  command = plan

  variables {
    quarantine_retention_days = 31
  }

  expect_failures = [var.quarantine_retention_days]
}

run "retention_fractional" {
  command = plan

  variables {
    quarantine_retention_days = 1.5
  }

  expect_failures = [var.quarantine_retention_days]
}

run "promoted_empty" {
  command = plan

  variables {
    promoted_prefixes = {}
  }

  expect_failures = [var.promoted_prefixes]
}

run "promoted_bad_grammar" {
  command = plan

  variables {
    promoted_prefixes = { "/mirror" = {} }
  }

  expect_failures = [var.promoted_prefixes]
}

run "promoted_nested" {
  command = plan

  variables {
    promoted_prefixes = { mirror = {}, "mirror/charts" = {} }
  }

  expect_failures = [var.promoted_prefixes]
}

run "promoted_equals_quarantine" {
  command = plan

  variables {
    promoted_prefixes = { quarantine = {} }
  }

  expect_failures = [var.promoted_prefixes]
}

run "promoted_inside_quarantine" {
  command = plan

  variables {
    promoted_prefixes = { "quarantine/mirror" = {} }
  }

  expect_failures = [var.promoted_prefixes]
}

run "promoted_contains_quarantine" {
  command = plan

  variables {
    quarantine_prefix = "mirror/quarantine"
    promoted_prefixes = { mirror = {} }
  }

  expect_failures = [var.promoted_prefixes]
}

run "exclusions_empty" {
  command = plan

  variables {
    promoted_prefixes = { mirror = { tag_mutability_exclusions = [] } }
  }

  expect_failures = [var.promoted_prefixes]
}

run "exclusions_over_five" {
  command = plan

  variables {
    promoted_prefixes = { mirror = { tag_mutability_exclusions = ["a", "b", "c", "d", "e", "f"] } }
  }

  expect_failures = [var.promoted_prefixes]
}

run "exclusion_whitespace" {
  command = plan

  variables {
    promoted_prefixes = { mirror = { tag_mutability_exclusions = ["sha256 *"] } }
  }

  expect_failures = [var.promoted_prefixes]
}

run "exclusion_duplicate" {
  command = plan

  variables {
    promoted_prefixes = { mirror = { tag_mutability_exclusions = ["sha256-*", "sha256-*"] } }
  }

  expect_failures = [var.promoted_prefixes]
}

run "writers_empty" {
  command = plan

  variables {
    writer_principal_arns = []
  }

  expect_failures = [var.writer_principal_arns]
}

run "writer_account_root" {
  command = plan

  variables {
    writer_principal_arns = ["arn:aws:iam::999999999999:root"]
  }

  expect_failures = [var.writer_principal_arns]
}

run "writer_wildcard" {
  command = plan

  variables {
    writer_principal_arns = ["arn:aws:iam::999999999999:role/*"]
  }

  expect_failures = [var.writer_principal_arns]
}

run "writer_padded" {
  command = plan

  variables {
    writer_principal_arns = ["arn:aws:iam::999999999999:role/writerx "]
  }

  expect_failures = [var.writer_principal_arns]
}

run "writer_duplicate_spelling" {
  command = plan

  variables {
    writer_principal_arns = ["arn:aws:iam::999999999999:role/writerx", "arn:aws:iam::999999999999:role/team/WRITERX"]
  }

  expect_failures = [var.writer_principal_arns]
}

run "intakes_empty" {
  command = plan

  variables {
    intake_principal_arns = []
  }

  expect_failures = [var.intake_principal_arns]
}

run "intake_account_root" {
  command = plan

  variables {
    intake_principal_arns = ["arn:aws:iam::999999999999:root"]
  }

  expect_failures = [var.intake_principal_arns]
}

run "intake_wildcard" {
  command = plan

  variables {
    intake_principal_arns = ["arn:aws:iam::999999999999:role/*"]
  }

  expect_failures = [var.intake_principal_arns]
}

run "intake_padded" {
  command = plan

  variables {
    intake_principal_arns = ["arn:aws:iam::999999999999:role/intakex "]
  }

  expect_failures = [var.intake_principal_arns]
}

run "intake_duplicate_spelling" {
  command = plan

  variables {
    intake_principal_arns = ["arn:aws:iam::999999999999:role/intakex", "arn:aws:iam::999999999999:role/team/INTAKEX"]
  }

  expect_failures = [var.intake_principal_arns]
}

run "admins_empty" {
  command = plan

  variables {
    admin_principal_arns = []
  }

  expect_failures = [var.admin_principal_arns]
}

run "admin_account_root" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:root"]
  }

  expect_failures = [var.admin_principal_arns]
}

run "admin_wildcard" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:role/*"]
  }

  expect_failures = [var.admin_principal_arns]
}

run "admin_padded" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:role/adminx "]
  }

  expect_failures = [var.admin_principal_arns]
}

run "admin_duplicate_spelling" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:role/adminx", "arn:aws:iam::999999999999:role/team/ADMINX"]
  }

  expect_failures = [var.admin_principal_arns]
}

run "writer_is_intake" {
  command = plan

  variables {
    intake_principal_arns = ["arn:aws:iam::999999999999:role/intake", "arn:aws:iam::999999999999:role/team/SYNC"]
  }

  expect_failures = [var.intake_principal_arns]
}

run "kms_alias_rejected" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:999999999999:alias/example-ecr"
  }

  expect_failures = [var.kms_key_arn]
}

run "target_arn_malformed" {
  command = plan

  variables {
    intake_event_target = { arn = "example-intake-queue" }
  }

  expect_failures = [var.intake_event_target]
}

run "target_role_not_a_role" {
  command = plan

  variables {
    intake_event_target = { arn = "arn:aws:sqs:us-east-1:999999999999:example-intake", role_arn = "arn:aws:iam::999999999999:user/events" }
  }

  expect_failures = [var.intake_event_target]
}

run "target_bus_without_role" {
  command = plan

  variables {
    intake_event_target = { arn = "arn:aws:events:us-east-1:111111111111:event-bus/example-intake" }
  }

  expect_failures = [var.intake_event_target]
}

run "target_state_machine_without_role" {
  command = plan

  variables {
    intake_event_target = { arn = "arn:aws:states:us-east-1:999999999999:stateMachine:example-intake" }
  }

  expect_failures = [var.intake_event_target]
}

run "writer_cross_account" {
  command = plan

  variables {
    writer_principal_arns = ["arn:aws:iam::111111111111:role/sync"]
  }

  expect_failures = [aws_ecr_repository_creation_template.quarantine]
}
