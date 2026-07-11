# Default-shape plan-time invariants per IMPL-0013 Phase 5.
#
# The cluster remote state is stubbed via override_data (Q2) — no S3
# backend, runs in seconds. Three runs exercise the for_each over
# var.replicas: a single-reader map, a three-reader map (per-reader
# instance_class / AZ / promotion_tier plumb through), and the empty map
# (zero readers). engine + engine_version are inherited from the stubbed
# cluster outputs, so the readers can't drift from the cluster.

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

run "single_reader" {
  command = plan

  variables {
    replicas = {
      primary = { instance_class = "db.r6g.large" }
    }
  }

  assert {
    condition     = length(aws_rds_cluster_instance.replica) == 1
    error_message = "A single-reader map must plan exactly one reader instance"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].identifier == "platform-rds-replica-primary"
    error_message = "Reader identifier must be <identifier_prefix>-replica-<key>"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].cluster_identifier == "platform-rds"
    error_message = "Reader must attach to the cluster_identifier read from remote state"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].engine == "aurora-postgresql"
    error_message = "Reader engine must be inherited from the cluster remote state"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].engine_version == "16.4"
    error_message = "Reader engine_version must be pinned to the cluster's engine_version_actual (Q5)"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].db_parameter_group_name == "platform-rds-instance-20260101"
    error_message = "Reader db_parameter_group_name must be inherited from the cluster remote state (Q5-a)"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].db_subnet_group_name == "platform-rds-rds-cluster"
    error_message = "Reader db_subnet_group_name must be inherited from the cluster remote state"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].promotion_tier == 15
    error_message = "Reader promotion_tier must default to 15 (below the writer's tier 0)"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["primary"].instance_class == "db.r6g.large"
    error_message = "Reader instance_class must come from the replicas entry"
  }
}

run "three_readers" {
  command = plan

  variables {
    replicas = {
      reader-a = { instance_class = "db.r6g.large", availability_zone = "us-east-1a", promotion_tier = 10 }
      reader-b = { instance_class = "db.r6g.xlarge", availability_zone = "us-east-1b" }
      reader-c = { instance_class = "db.t4g.medium", publicly_accessible = false }
    }
  }

  assert {
    condition     = length(aws_rds_cluster_instance.replica) == 3
    error_message = "A three-reader map must plan exactly three reader instances"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-a"].identifier == "platform-rds-replica-reader-a"
    error_message = "reader-a identifier must compose from its key"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-b"].instance_class == "db.r6g.xlarge"
    error_message = "Per-reader instance_class must plumb through independently"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-a"].availability_zone == "us-east-1a"
    error_message = "Per-reader availability_zone must plumb through"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-a"].promotion_tier == 10
    error_message = "Per-reader promotion_tier override must plumb through"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-c"].promotion_tier == 15
    error_message = "A reader without an explicit promotion_tier must default to 15"
  }
}

run "empty_map" {
  command = plan

  variables {
    replicas = {}
  }

  assert {
    condition     = length(aws_rds_cluster_instance.replica) == 0
    error_message = "An empty replicas map must plan zero reader instances"
  }
}
