# Default-shape resource counts.
#
# With module-managed KMS (var.kms_key_arn = null) and SSM publication
# off (var.publish_to_ssm = false default), the module plans:
#   - 1 aws_kms_key + 1 aws_kms_alias
#   - 1 aws_iam_role.ecr_template + 1 aws_iam_role_policy.ecr_template
#   - 2 aws_ecr_repository_creation_template (helm_charts + tf_modules)
#   - 1 aws_iam_policy.oci_publisher
#   - 0 aws_ssm_parameter resources

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
}

run "plan_default" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = length(aws_kms_key.ecr_oci) == 1
    error_message = "Default shape must plan exactly 1 module-managed aws_kms_key.ecr_oci"
  }

  assert {
    condition     = length(aws_kms_alias.ecr_oci) == 1
    error_message = "Default shape must plan exactly 1 module-managed aws_kms_alias.ecr_oci"
  }

  assert {
    condition     = aws_iam_role.ecr_template.name == "platform-ecr-template"
    error_message = "ECR-template role name must compose to <name_prefix>-ecr-template"
  }

  assert {
    condition     = aws_iam_role_policy.ecr_template.name == "platform-ecr-template-permissions"
    error_message = "ECR-template inline role-policy must be present and correctly named"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.helm_charts.prefix == "helm-charts" && aws_ecr_repository_creation_template.tf_modules.prefix == "tf-modules"
    error_message = "Both creation templates must plan with their default prefixes"
  }

  assert {
    condition     = aws_iam_policy.oci_publisher.name == "platform-oci-publisher"
    error_message = "Publisher policy name must compose to <name_prefix>-oci-publisher"
  }

  assert {
    condition     = length(aws_ssm_parameter.publisher_policy_arn) == 0 && length(aws_ssm_parameter.publisher_policy_json) == 0
    error_message = "Default publish_to_ssm = false must plan zero SSM parameters"
  }
}
