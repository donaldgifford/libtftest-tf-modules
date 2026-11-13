# Fail-closed rejections (DESIGN-0031 / IMPL-0027 Phase 3).
#
# VERIFICATION DISCIPLINE: expect_failures proves the variable errored,
# not which rule fired, and four or five rules stack on each principal
# list. Every rejection was message-probed in isolation (IMPL-0027
# Phase 3 transcript). Positive runs live in key.tftest.hcl.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "999999999999"
      arn        = "arn:aws:sts::999999999999:assumed-role/deploy/terraform-session"
    }
  }

  mock_resource "aws_kms_key" {
    override_during = plan
    defaults = {
      arn    = "arn:aws:kms:us-east-1:999999999999:key/11111111-2222-3333-4444-555555555555"
      key_id = "11111111-2222-3333-4444-555555555555"
    }
  }
}

variables {
  name                  = "example-mirror-signing"
  admin_principal_arns  = ["arn:aws:iam::999999999999:role/deploy"]
  signer_principal_arns = ["arn:aws:iam::999999999999:role/intake"]
}

run "name_bad_charset" {
  command = plan

  variables {
    name = "example signing"
  }

  expect_failures = [var.name]
}

run "name_reserved_aws_prefix" {
  command = plan

  variables {
    name = "aws/signing"
  }

  expect_failures = [var.name]
}

run "key_spec_unsupported" {
  command = plan

  variables {
    key_spec = "ECC_SECG_P256K1"
  }

  expect_failures = [var.key_spec]
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
    admin_principal_arns = ["arn:aws:iam::999999999999:role/deploy", "arn:aws:iam::999999999999:role/ops-*"]
  }

  expect_failures = [var.admin_principal_arns]
}

run "admin_padded" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:role/deploy", "arn:aws:iam::999999999999:role/ops "]
  }

  expect_failures = [var.admin_principal_arns]
}

run "admin_duplicate_spelling" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:role/deploy", "arn:aws:iam::999999999999:role/team/Deploy"]
  }

  expect_failures = [var.admin_principal_arns]
}

run "signers_empty" {
  command = plan

  variables {
    signer_principal_arns = []
  }

  expect_failures = [var.signer_principal_arns]
}

run "signer_service_principal" {
  command = plan

  variables {
    signer_principal_arns = ["ecr.amazonaws.com"]
  }

  expect_failures = [var.signer_principal_arns]
}

run "signer_duplicate" {
  command = plan

  variables {
    signer_principal_arns = ["arn:aws:iam::999999999999:role/intake", "arn:aws:iam::999999999999:role/intake"]
  }

  expect_failures = [var.signer_principal_arns]
}

run "signer_is_admin" {
  command = plan

  variables {
    signer_principal_arns = ["arn:aws:iam::999999999999:role/platform/Deploy"]
  }

  expect_failures = [var.signer_principal_arns]
}

run "verifier_wildcard" {
  command = plan

  variables {
    verifier_principal_arns = ["arn:aws:iam::111111111111:role/*"]
  }

  expect_failures = [var.verifier_principal_arns]
}

run "caller_not_admin" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:role/key-admin"]
  }

  expect_failures = [aws_kms_key.this]
}
