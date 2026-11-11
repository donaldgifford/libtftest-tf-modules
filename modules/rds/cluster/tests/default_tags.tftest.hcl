# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the cluster, its writer and its security group.

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
  region                    = "us-east-1"
  remote_state_bucket       = "stub-bucket"
  vpc_name                  = "libtftest-vpc"
  identifier_prefix         = "platform-rds"
  instance_class            = "db.r6g.large"
  final_snapshot_identifier = "platform-rds-final-test"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "default_tags_reach_resources" {
  command = plan

  variables {
    engine = "aurora-postgresql"
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      }
    }
  }

  assert {
    condition     = aws_rds_cluster.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the cluster (tags_all)"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the writer instance (tags_all)"
  }

  assert {
    condition     = aws_security_group.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the security group (tags_all)"
  }
}
