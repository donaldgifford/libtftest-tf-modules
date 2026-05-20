# Prefix overrides flow into templates and publisher policy.
#
# Overriding var.helm_charts_prefix and var.tf_modules_prefix must
# propagate to both templates' prefix attribute and to the publisher
# policy's resource ARNs.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name_prefix          = "platform"
  organizations_org_id = "o-test1234ab"
  helm_charts_prefix   = "internal-charts"
  tf_modules_prefix    = "internal-modules"
  # BYO KMS so local.kms_key_arn is plan-known (publisher policy JSON
  # references it; the module-managed key's ARN is unknown until apply).
  kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "custom_prefixes" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = aws_ecr_repository_creation_template.helm_charts.prefix == "internal-charts"
    error_message = "helm_charts template prefix must reflect the var override"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.tf_modules.prefix == "internal-modules"
    error_message = "tf_modules template prefix must reflect the var override"
  }

  assert {
    condition     = strcontains(aws_iam_policy.oci_publisher.policy, "repository/internal-charts/*")
    error_message = "Publisher policy must reflect the overridden helm_charts_prefix"
  }

  assert {
    condition     = strcontains(aws_iam_policy.oci_publisher.policy, "repository/internal-modules/*")
    error_message = "Publisher policy must reflect the overridden tf_modules_prefix"
  }
}
