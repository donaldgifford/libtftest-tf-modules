# Parameter family resolution: engine + engine_version → family map
# lookup. Three runs exercise the resolution logic:
#   1. Explicit engine_version "16" on postgres → aurora-postgresql16
#   2. Explicit engine_version "8.0" on MySQL → aurora-mysql8.0
#   3. var.parameter_family override wins over the lookup

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
  min_acu                   = 0.5
  max_acu                   = 4
  final_snapshot_identifier = "platform-rds-final-test"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "postgres_explicit_version" {
  command = plan

  variables {
    engine         = "aurora-postgresql"
    engine_version = "15"
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
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-postgresql15"
    error_message = "engine_version 15 must resolve to aurora-postgresql15 family"
  }
}

run "mysql_explicit_version" {
  command = plan

  variables {
    engine         = "aurora-mysql"
    engine_version = "8.0"
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
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-mysql8.0"
    error_message = "engine_version 8.0 must resolve to aurora-mysql8.0 family"
  }
}

run "parameter_family_override" {
  command = plan

  variables {
    engine           = "aurora-postgresql"
    parameter_family = "aurora-postgresql14"
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
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-postgresql14"
    error_message = "Explicit var.parameter_family must win over the lookup map"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "aurora-postgresql14"
    error_message = "Instance parameter group family must also honor the override"
  }
}
