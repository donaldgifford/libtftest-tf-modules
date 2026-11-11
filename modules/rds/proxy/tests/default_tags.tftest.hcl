# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the proxy, its IAM role and its security group.

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
  name                = "platform-proxy"
  remote_state_bucket = "stub-bucket"
}

run "default_tags_reach_resources" {
  command = plan

  variables {
    target_type       = "rds-instance"
    target_identifier = "platform-db"
  }

  override_data {
    target = data.terraform_remote_state.target
    values = {
      outputs = {
        master_user_secret_arn              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds-abc"
        master_user_secret_kms_key_arn      = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
        security_group_id                   = "sg-0123456789abcdef0"
        db_subnet_ids                       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        vpc_id                              = "vpc-0123456789abcdef0"
        engine                              = "postgres"
        iam_database_authentication_enabled = false
      }
    }
  }

  assert {
    condition     = aws_db_proxy.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the proxy (tags_all)"
  }

  assert {
    condition     = aws_iam_role.proxy.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the proxy IAM role (tags_all)"
  }

  assert {
    condition     = aws_security_group.proxy.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the proxy security group (tags_all)"
  }
}
