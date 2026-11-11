# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the secret.

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
  name = "platform-db-master"
}

run "default_tags_reach_the_secret" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the secret (tags_all)"
  }
}
