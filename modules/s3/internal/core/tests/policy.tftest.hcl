# Policy composition: opt-in VPCE deny + additive statement injection
# (IMPL-0018 1.8 / DESIGN-0019 OQ 4b). Single-element condition values
# render as JSON strings (not lists), so value checks use strcontains
# on the rendered document rather than list traversal.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "core-test"
}

run "vpce_restriction_opt_in" {
  command = plan

  variables {
    allowed_vpc_endpoint_ids = ["vpce-0123456789abcdef0"]
  }

  assert {
    condition     = contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyOutsideVpce")
    error_message = "non-empty allowed_vpc_endpoint_ids must render the DenyOutsideVpce statement"
  }

  assert {
    condition     = strcontains(data.aws_iam_policy_document.bucket.json, "vpce-0123456789abcdef0")
    error_message = "the VPCE deny must carry the allowed endpoint id"
  }

  assert {
    condition     = output.security_baseline.vpce_restricted == true
    error_message = "security_baseline.vpce_restricted must reflect the opt-in"
  }
}

run "internal_statements_additive" {
  command = plan

  variables {
    internal_policy_statements = [{
      sid               = "TestGrant"
      principals        = { Service = ["logging.s3.amazonaws.com"] }
      actions           = ["s3:PutObject"]
      resource_suffixes = ["/*"]
      conditions = [{
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = ["000000000000"]
      }]
    }]
  }

  assert {
    condition     = contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "TestGrant")
    error_message = "injected statements must render"
  }

  assert {
    condition     = one([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s if s.Sid == "TestGrant"]).Resource == "arn:aws:s3:::core-test-000000000000-us-east-1/*"
    error_message = "resource_suffixes must expand against the composed bucket ARN"
  }

  assert {
    condition = alltrue([
      contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyInsecureTransport"),
      contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyOldTls"),
    ])
    error_message = "the baseline denies must still render beside injected statements (additive-only merge)"
  }
}
