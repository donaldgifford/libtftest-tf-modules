# Validation negatives — variable.validation blocks + reader lifecycle
# preconditions. Each run wires expect_failures at the appropriate target
# (variable for variable.validation, resource for precondition). The
# cluster remote state is stubbed via override_data; the stale-state run
# overrides it with a null cluster_identifier to trip the Q7 precondition.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  cluster_identifier  = "platform-rds"
  identifier_prefix   = "platform-rds"
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

run "identifier_prefix_rejected" {
  command = plan

  variables {
    identifier_prefix = "InvalidUpperCase"
  }

  expect_failures = [
    var.identifier_prefix,
  ]
}

run "cluster_identifier_rejected" {
  command = plan

  variables {
    cluster_identifier = "Invalid_Cluster"
  }

  expect_failures = [
    var.cluster_identifier,
  ]
}

run "promotion_tier_out_of_range" {
  command = plan

  variables {
    replicas = {
      primary = { instance_class = "db.r6g.large", promotion_tier = 20 }
    }
  }

  expect_failures = [
    var.replicas,
  ]
}

run "replica_key_rejected" {
  command = plan

  variables {
    replicas = {
      "Reader_A" = { instance_class = "db.r6g.large" }
    }
  }

  expect_failures = [
    var.replicas,
  ]
}

run "enhanced_monitoring_requires_role" {
  command = plan

  variables {
    replicas = {
      primary = { instance_class = "db.r6g.large", monitoring_interval = 30 }
    }
  }

  expect_failures = [
    aws_rds_cluster_instance.replica,
  ]
}

run "stale_cluster_state" {
  command = plan

  override_data {
    target = data.terraform_remote_state.rds_cluster
    values = {
      outputs = {
        cluster_identifier      = null
        engine                  = "aurora-postgresql"
        engine_version_actual   = "16.4"
        db_subnet_group_name    = "platform-rds-rds-cluster"
        db_parameter_group_name = "platform-rds-instance-20260101"
      }
    }
  }

  expect_failures = [
    aws_rds_cluster_instance.replica,
  ]
}
