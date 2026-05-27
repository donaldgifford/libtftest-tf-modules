# Validation negatives — variable.validation blocks + cluster lifecycle
# preconditions. Each run wires expect_failures at the appropriate
# target (variable for variable.validation, resource for precondition).

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

run "engine_rejected" {
  command = plan

  variables {
    engine = "postgres"
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

  expect_failures = [
    var.engine,
  ]
}

run "engine_version_rejected" {
  command = plan

  variables {
    engine_version = "16-beta"
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

  expect_failures = [
    var.engine_version,
  ]
}

run "min_acu_too_small" {
  command = plan

  variables {
    min_acu = 0
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

  expect_failures = [
    var.min_acu,
  ]
}

run "max_acu_too_big" {
  command = plan

  variables {
    max_acu = 512
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

  expect_failures = [
    var.max_acu,
  ]
}

run "min_greater_than_max" {
  command = plan

  variables {
    min_acu = 8
    max_acu = 4
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

  expect_failures = [
    aws_rds_cluster.this,
  ]
}

run "backup_retention_zero" {
  command = plan

  variables {
    backup_retention_period = 0
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

  expect_failures = [
    var.backup_retention_period,
  ]
}

run "identifier_uppercase_rejected" {
  command = plan

  variables {
    identifier_prefix = "InvalidUpperCase"
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

  expect_failures = [
    var.identifier_prefix,
  ]
}

run "snapshot_required_when_not_skipping" {
  command = plan

  variables {
    skip_final_snapshot       = false
    final_snapshot_identifier = null
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

  expect_failures = [
    aws_rds_cluster.this,
  ]
}

run "enhanced_monitoring_requires_role" {
  command = plan

  variables {
    enhanced_monitoring_interval = 30
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

  expect_failures = [
    aws_rds_cluster_instance.this,
  ]
}
