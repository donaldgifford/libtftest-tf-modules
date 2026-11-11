# Provider default_tags coverage (DESIGN-0029 / IMPL-0026).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags. The creation template is the one
# place that set cannot reach on its own: resource_tags is applied by ECR
# to the cache repositories it creates on first pull, which the provider
# never manages. So the module reads the set back via data.aws_default_tags.
# This run pins that the probe key reaches resource_tags.

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
  region              = "us-east-1"
  name_prefix         = "libtftest"
  upstream_registries = ["ecr-public"]
}

run "creation_template_carries_default_tags" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = aws_ecr_repository_creation_template.pull_through.resource_tags == tomap({ DefaultTagProbe = "design-0029" })
    error_message = "the creation template's resource_tags must be exactly the provider default_tags"
  }
}
