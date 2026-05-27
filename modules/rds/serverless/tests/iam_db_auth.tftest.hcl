# IAM database authentication toggle (per IMPL-0007 / DESIGN-0007 Q5).
#
# Default false; opt-in by setting var.iam_database_authentication_enabled.
# When enabled, the cluster attribute resolves to true — consumers obtain
# a connection token via `aws rds generate-db-auth-token`.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region                    = "us-east-1"
  remote_state_bucket       = "stub-bucket"
  vpc_name                  = "libtftest-vpc"
  identifier_prefix         = "platform-rds"
  engine                    = "aurora-postgresql"
  min_acu                   = 0.5
  max_acu                   = 4
  final_snapshot_identifier = "platform-rds-final-test"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "iam_auth_off_by_default" {
  command = plan

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
    condition     = aws_rds_cluster.this.iam_database_authentication_enabled == false
    error_message = "iam_database_authentication_enabled must default to false"
  }
}

run "iam_auth_opt_in" {
  command = plan

  variables {
    iam_database_authentication_enabled = true
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
    condition     = aws_rds_cluster.this.iam_database_authentication_enabled == true
    error_message = "iam_database_authentication_enabled must resolve to true when opted-in"
  }
}
