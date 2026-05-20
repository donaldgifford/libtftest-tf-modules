# Org-wide pull policy reaches both templates.
#
# data.aws_iam_policy_document.org_pull is a single declaration
# referenced by both templates' repository_policy. Assert the encoded
# JSON contains aws:PrincipalOrgID and the supplied org ID — the
# shared-source contract is the regression target (renaming or
# duplicating the policy doc would break this).

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

run "plan_org_pull" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.helm_charts.repository_policy, "aws:PrincipalOrgID") && strcontains(aws_ecr_repository_creation_template.helm_charts.repository_policy, "o-test1234ab")
    error_message = "helm_charts repository_policy must contain aws:PrincipalOrgID and the supplied org ID"
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.tf_modules.repository_policy, "aws:PrincipalOrgID") && strcontains(aws_ecr_repository_creation_template.tf_modules.repository_policy, "o-test1234ab")
    error_message = "tf_modules repository_policy must contain aws:PrincipalOrgID and the supplied org ID (proves the shared policy doc reaches both templates)"
  }
}
