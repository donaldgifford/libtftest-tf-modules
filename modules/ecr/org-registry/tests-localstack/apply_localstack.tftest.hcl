# Apply against LocalStack — gap-discovery mode per RFC-0001.
#
# This module's two creation templates rely on the ECR
# CreateRepositoryCreationTemplate API. IMPL-0005 Phase 9 found this
# API returns 501/NotImplemented on LocalStack Pro 2026.5.0 (see
# `modules/ecr/pull-through-cache/tests-localstack/FINDINGS.md`). The
# same gap applies here: a full apply hits the same 501 on both Pro
# and Community tiers.
#
# Per the established IMPL-0005 Phase 9 pattern, the active run is a
# `plan_smoke` against LocalStack endpoints; the full apply is
# preserved as commented HCL for re-enable when LocalStack lands the
# missing API.
#
# Required env vars (the `just tf test-localstack` recipe wires these
# automatically):
#
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# Findings captured in FINDINGS.md.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ecr = "http://localhost:4566"
    iam = "http://localhost:4566"
    kms = "http://localhost:4566"
    ssm = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}

variables {
  name_prefix          = "tftest-ocr"
  organizations_org_id = "o-tftest1234"
  tags = {
    Environment = "test"
    ManagedBy   = "libtftest"
  }
}

# Plan-only smoke against the LocalStack endpoint. Validates that:
#
#   - The provider resolves STS GetCallerIdentity through LocalStack
#     (real account ID returned, not the fake stub).
#   - Every resource in the module validates at plan time against
#     LocalStack's AWS API surface.
#
# Real apply assertions on the creation templates require LocalStack
# CreateRepositoryCreationTemplate implementation (FINDINGS.md
# Finding #1, inherited from IMPL-0005).
run "plan_smoke" {
  command = plan

  assert {
    condition     = length(aws_kms_key.ecr_oci) == 1
    error_message = "Module must plan exactly 1 module-managed KMS key (default shape)"
  }

  assert {
    condition     = length(aws_kms_alias.ecr_oci) == 1
    error_message = "Module must plan exactly 1 module-managed KMS alias"
  }

  assert {
    condition     = aws_iam_role.ecr_template.name == "tftest-ocr-ecr-template"
    error_message = "ECR-template role name must compose from name_prefix"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.helm_charts.prefix == "helm-charts" && aws_ecr_repository_creation_template.tf_modules.prefix == "tf-modules"
    error_message = "Both creation templates must plan with default prefixes"
  }

  assert {
    condition     = aws_iam_policy.oci_publisher.name == "tftest-ocr-oci-publisher"
    error_message = "Publisher policy name must compose from name_prefix"
  }
}

# Apply run preserved for the day LocalStack lands
# CreateRepositoryCreationTemplate. Uncomment after the inherited
# IMPL-0005 Finding #1 closes (re-run probe per
# `modules/ecr/pull-through-cache/tests-localstack/FINDINGS.md` →
# "When to re-run").
#
# run "apply_default" {
#   command = apply
#
#   assert {
#     condition     = length(aws_kms_key.ecr_oci[0].arn) > 0
#     error_message = "LocalStack KMS must populate the module-managed key ARN"
#   }
#   assert {
#     condition     = length(aws_kms_alias.ecr_oci[0].arn) > 0
#     error_message = "LocalStack KMS must populate the alias ARN"
#   }
#   assert {
#     condition     = length(aws_iam_role.ecr_template.arn) > 0
#     error_message = "LocalStack IAM must populate the ECR-template role ARN"
#   }
#   assert {
#     condition     = length(aws_ecr_repository_creation_template.helm_charts.id) > 0
#     error_message = "LocalStack ECR must populate the helm_charts creation template ID"
#   }
#   assert {
#     condition     = length(aws_ecr_repository_creation_template.tf_modules.id) > 0
#     error_message = "LocalStack ECR must populate the tf_modules creation template ID"
#   }
#   assert {
#     condition     = length(aws_iam_policy.oci_publisher.arn) > 0
#     error_message = "LocalStack IAM must populate the publisher policy ARN"
#   }
# }
