# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches a reader instance.

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
  remote_state_bucket = "stub-bucket"
  cluster_identifier  = "platform-rds"
  identifier_prefix   = "platform-rds"
}

run "default_tags_reach_readers" {
  command = plan

  variables {
    replicas = {
      primary = { instance_class = "db.r6g.large" }
    }
  }

  override_data {
    target = data.terraform_remote_state.rds_cluster
    values = {
      outputs = {
        cluster_identifier      = "platform-rds"
        engine                  = "aurora-postgresql"
        engine_version_actual   = "16.4"
        db_subnet_group_name    = "platform-rds-rds-cluster"
        db_parameter_group_name = "platform-rds-instance-20260101"
      }
    }
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the reader instance (tags_all)"
  }
}
