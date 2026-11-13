# Signing key shape (DESIGN-0031 § kms/signing-key).
#
# The key policy is decoded statement by statement. LocalStack does not
# enforce key policies (DESIGN-0031 probe), so THIS suite is the only
# tier that proves the no-root-delegation shape.

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
  admin_principal_arns  = ["arn:aws:iam::999999999999:role/deploy", "arn:aws:iam::999999999999:role/platform/key-admin"]
  signer_principal_arns = ["arn:aws:iam::999999999999:role/intake"]
}

# Pins every default.
run "bare_call_pins_defaults" {
  command = plan

  assert {
    condition     = aws_kms_key.this.key_usage == "SIGN_VERIFY" && aws_kms_key.this.customer_master_key_spec == "ECC_NIST_P256"
    error_message = "the key must be a SIGN_VERIFY ECC_NIST_P256 key by default"
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == false
    error_message = "rotation must be pinned off: asymmetric keys cannot rotate (LocalStack accepts it anyway, so only this run guards it)"
  }

  assert {
    condition     = aws_kms_key.this.deletion_window_in_days == 30 && aws_kms_key.this.bypass_policy_lockout_safety_check == false
    error_message = "the 30-day deletion window and the KMS lockout safety check must be pinned"
  }

  assert {
    condition     = aws_kms_alias.this.name == "alias/example-mirror-signing"
    error_message = "the alias must be alias/<name>"
  }
}

run "key_policy_has_no_root_delegation" {
  command = plan

  assert {
    condition     = [for st in jsondecode(aws_kms_key.this.policy).Statement : st.Sid] == ["KeyAdministration", "AllowSign"]
    error_message = "without verifiers the policy is exactly KeyAdministration + AllowSign"
  }

  assert {
    condition = alltrue(flatten([
      for st in jsondecode(aws_kms_key.this.policy).Statement : [for p in st.Principal.AWS : !endswith(p, ":root")]
    ]))
    error_message = "no statement may delegate to an account root: account IAM must not be able to add signers"
  }

  assert {
    condition     = jsondecode(aws_kms_key.this.policy).Statement[0].NotAction == ["kms:Sign"] && !contains(keys(jsondecode(aws_kms_key.this.policy).Statement[0]), "Action")
    error_message = "admins get everything EXCEPT kms:Sign"
  }

  assert {
    condition     = jsondecode(aws_kms_key.this.policy).Statement[0].Principal.AWS == ["arn:aws:iam::999999999999:role/deploy", "arn:aws:iam::999999999999:role/platform/key-admin"]
    error_message = "the admin statement must name exactly the admin principals, sorted, as a list"
  }

  assert {
    condition     = jsondecode(aws_kms_key.this.policy).Statement[1].Principal.AWS == ["arn:aws:iam::999999999999:role/intake"]
    error_message = "the sign statement must name exactly the signers, as a list"
  }

  assert {
    condition     = jsondecode(aws_kms_key.this.policy).Statement[1].Action == ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
    error_message = "signers get Sign, GetPublicKey and DescribeKey only"
  }
}

run "verifiers_add_a_verify_statement" {
  command = plan

  variables {
    verifier_principal_arns = ["arn:aws:iam::111111111111:role/admission"]
  }

  assert {
    condition     = [for st in jsondecode(aws_kms_key.this.policy).Statement : st.Sid] == ["KeyAdministration", "AllowSign", "AllowVerify"]
    error_message = "verifiers add an AllowVerify statement after AllowSign"
  }

  assert {
    condition     = jsondecode(aws_kms_key.this.policy).Statement[2].Principal.AWS == ["arn:aws:iam::111111111111:role/admission"] && jsondecode(aws_kms_key.this.policy).Statement[2].Action == ["kms:DescribeKey", "kms:GetPublicKey", "kms:Verify"]
    error_message = "verifiers get Verify, GetPublicKey and DescribeKey, never Sign"
  }
}

run "rsa_key_spec_accepted" {
  command = plan

  variables {
    key_spec = "RSA_4096"
  }

  assert {
    condition     = aws_kms_key.this.customer_master_key_spec == "RSA_4096"
    error_message = "RSA_4096 must be accepted"
  }
}

run "outputs" {
  command = plan

  assert {
    condition     = output.cosign_key_ref == "awskms:///arn:aws:kms:us-east-1:999999999999:key/11111111-2222-3333-4444-555555555555"
    error_message = "cosign_key_ref must use the KEY ARN (aliases do not resolve cross-account)"
  }

  assert {
    condition     = jsondecode(output.signer_policy_json).Statement[0].Action == ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
    error_message = "the cross-account signer grant carries exactly the sign actions"
  }

  assert {
    condition     = jsondecode(output.signer_policy_json).Statement[0].Resource == ["arn:aws:kms:us-east-1:999999999999:key/11111111-2222-3333-4444-555555555555"]
    error_message = "the cross-account signer grant is scoped to this key only"
  }

  # public_key_pem is NOT asserted here: the data source reads a key that
  # does not exist yet, so Terraform defers it to apply and no mock can
  # make it known at plan. The Community apply suite asserts it.
}

# The deploy role is matched through its path-stripped name, so an admin
# ARN with a path still satisfies the caller precondition.
run "caller_matches_path_bearing_admin" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::999999999999:role/automation/Deploy"]
  }

  assert {
    condition     = length(jsondecode(aws_kms_key.this.policy).Statement) == 2
    error_message = "an assumed-role caller must match its path-bearing, differently-cased admin ARN"
  }
}
