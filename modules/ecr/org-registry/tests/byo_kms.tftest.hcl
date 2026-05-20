# Bring-your-own KMS shape.
#
# Supplying var.kms_key_arn short-circuits the module-managed key:
# zero aws_kms_key + aws_kms_alias resources, and local.kms_key_arn
# echoes the BYO ARN. Both templates' encryption_configuration and
# the ECR-template role-policy reference the BYO ARN at plan time.

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
  kms_key_arn          = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "plan_byo_kms" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = length(aws_kms_key.ecr_oci) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_key resources"
  }

  assert {
    condition     = length(aws_kms_alias.ecr_oci) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_alias resources"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.helm_charts.encryption_configuration[0].kms_key == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "helm_charts template encryption_configuration.kms_key must equal the BYO ARN"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.tf_modules.encryption_configuration[0].kms_key == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "tf_modules template encryption_configuration.kms_key must equal the BYO ARN"
  }

  assert {
    condition     = strcontains(data.aws_iam_policy_document.ecr_template.json, "arn:aws:kms:us-east-1:000000000000:key/byo-1234")
    error_message = "ECR-template role-policy JSON must contain the BYO KMS ARN in its UseKmsKey statement"
  }
}
