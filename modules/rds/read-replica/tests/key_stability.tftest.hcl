# for_each key stability (IMPL-0013 Phase 5).
#
# The readers use for_each over a map (not count), so each reader is
# addressed by its key, not a positional index. Removing a middle key
# must NOT renumber the survivors — reader-a and reader-c keep their
# identifiers whether or not reader-b is present. Two runs assert the
# identifiers by key: the full three-key map, then the map with the
# middle key removed.

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

run "all_three_keys" {
  command = plan

  variables {
    replicas = {
      reader-a = { instance_class = "db.r6g.large" }
      reader-b = { instance_class = "db.r6g.large" }
      reader-c = { instance_class = "db.r6g.large" }
    }
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-a"].identifier == "platform-rds-replica-reader-a"
    error_message = "reader-a identifier must be keyed by its map key"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-c"].identifier == "platform-rds-replica-reader-c"
    error_message = "reader-c identifier must be keyed by its map key"
  }
}

run "middle_key_removed" {
  command = plan

  variables {
    replicas = {
      reader-a = { instance_class = "db.r6g.large" }
      reader-c = { instance_class = "db.r6g.large" }
    }
  }

  assert {
    condition     = length(aws_rds_cluster_instance.replica) == 2
    error_message = "Removing the middle key must leave exactly two readers"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-a"].identifier == "platform-rds-replica-reader-a"
    error_message = "reader-a identifier must be unchanged after the middle key is removed (for_each, not count)"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["reader-c"].identifier == "platform-rds-replica-reader-c"
    error_message = "reader-c identifier must be unchanged (not renumbered) after the middle key is removed"
  }
}
