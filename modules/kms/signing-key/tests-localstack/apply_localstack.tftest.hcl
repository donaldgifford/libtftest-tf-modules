# Apply against token-free LocalStack Community 4.4 (IMPL-0027 Phase 3).
#
# WHAT THIS SUITE DOES NOT PROVE (FINDINGS.md leads with both):
#   - that the key policy is ENFORCED: 4.4 ignores key policies, so a
#     principal outside AllowSign can still sign here;
#   - that rotation is refused: 4.4 accepts EnableKeyRotation on an
#     asymmetric key, which real AWS rejects.
# The plan suite owns both. This suite proves wiring: the key is created
# with the right usage and spec, the alias resolves to it, and the
# public key is served.
#
# The endpoint comes from AWS_ENDPOINT_URL (no hardcoded endpoints
# block), so the suite runs against whichever port the container uses.
# The `just tf test-localstack` recipe wires :4566 and the test creds.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  # The module's precondition requires the APPLYING principal to be a key
  # admin. LocalStack STS mints credentials for any role ARN, so assuming
  # a "deploy" role makes the caller an assumed-role ARN that matches
  # admin_principal_arns below, exactly as an Atlantis deploy role would.
  assume_role {
    role_arn     = "arn:aws:iam::000000000000:role/deploy"
    session_name = "libtftest"
  }

  default_tags {
    tags = { ManagedBy = "terraform", Suite = "kms-signing-key" }
  }
}

variables {
  name                  = "example-mirror-signing"
  admin_principal_arns  = ["arn:aws:iam::000000000000:role/deploy"]
  signer_principal_arns = ["arn:aws:iam::000000000000:role/intake"]
}

run "apply_signing_key" {
  command = apply

  assert {
    condition     = aws_kms_key.this.key_usage == "SIGN_VERIFY" && aws_kms_key.this.customer_master_key_spec == "ECC_NIST_P256"
    error_message = "the applied key must be SIGN_VERIFY / ECC_NIST_P256"
  }

  assert {
    condition     = startswith(output.public_key_pem, "-----BEGIN PUBLIC KEY-----")
    error_message = "public_key_pem must be a PEM public key served by GetPublicKey"
  }

  assert {
    condition     = output.cosign_key_ref == "awskms:///${aws_kms_key.this.arn}"
    error_message = "cosign_key_ref must reference the applied key ARN"
  }

  assert {
    condition     = output.alias_name == "alias/example-mirror-signing"
    error_message = "the alias must be alias/<name>"
  }
}

run "verify_readback" {
  command = apply

  module {
    source = "./tests-localstack/fixtures/verify"
  }

  variables {
    alias_name = run.apply_signing_key.alias_name
  }

  assert {
    condition     = output.target_key_arn == run.apply_signing_key.key_arn
    error_message = "the alias must resolve to the module's key"
  }

  assert {
    condition     = output.key_usage == "SIGN_VERIFY" && output.key_spec == "ECC_NIST_P256"
    error_message = "KMS must serve back the key's usage and spec"
  }
}
