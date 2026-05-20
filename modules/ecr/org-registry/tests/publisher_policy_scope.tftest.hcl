# Publisher policy is scoped to both managed prefixes.
#
# The EcrCreateAndPush statement's Resource array must contain both
# managed-prefix ARNs (helm-charts and tf-modules), and EcrAuth must
# keep "*" as Resource (AWS API limitation — ecr:GetAuthorizationToken
# only accepts wildcard).

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
  # BYO KMS so local.kms_key_arn is plan-known. The publisher policy's
  # UseKmsForEncryption statement embeds local.kms_key_arn — without
  # a BYO value, the module-managed aws_kms_key.ecr_oci[0].arn is
  # unknown at plan and the whole policy JSON becomes unknown.
  kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "scope_managed_prefixes" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = strcontains(aws_iam_policy.oci_publisher.policy, "arn:aws:ecr:*:000000000000:repository/helm-charts/*")
    error_message = "Publisher policy must contain the helm-charts-prefix ARN"
  }

  assert {
    condition     = strcontains(aws_iam_policy.oci_publisher.policy, "arn:aws:ecr:*:000000000000:repository/tf-modules/*")
    error_message = "Publisher policy must contain the tf-modules-prefix ARN"
  }

  assert {
    condition     = strcontains(aws_iam_policy.oci_publisher.policy, "ecr:GetAuthorizationToken")
    error_message = "Publisher policy must contain ecr:GetAuthorizationToken"
  }
}
