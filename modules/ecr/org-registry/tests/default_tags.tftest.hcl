# Provider default_tags coverage (DESIGN-0029 / IMPL-0026).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags. The creation templates are the one
# place that set cannot reach on its own: resource_tags is applied by ECR
# to repositories created LATER, which the provider never manages. So the
# module reads the set back via data.aws_default_tags and merges its own
# keys on top. These runs pin that the probe key reaches resource_tags.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  default_tags {
    tags = { DefaultTagProbe = "design-0029" }
  }
}

variables {
  name_prefix          = "platform"
  organizations_org_id = "o-test1234ab"
}

run "creation_templates_carry_default_tags" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition = aws_ecr_repository_creation_template.helm_charts.resource_tags == tomap({
      DefaultTagProbe = "design-0029"
      artifact_type   = "helm-chart"
      managed_by      = "platform"
    })
    error_message = "helm-charts resource_tags must be the provider default_tags plus the module's artifact_type/managed_by keys"
  }

  assert {
    condition = aws_ecr_repository_creation_template.tf_modules.resource_tags == tomap({
      DefaultTagProbe = "design-0029"
      artifact_type   = "terraform-module"
      managed_by      = "platform"
    })
    error_message = "tf-modules resource_tags must be the provider default_tags plus the module's artifact_type/managed_by keys"
  }
}
