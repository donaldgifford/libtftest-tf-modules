# Plan-time default-shape invariants per IMPL-0010 Phase 9 / ADR-0013.
# Remote state is stubbed via override_data (Q2-a) — no S3 backend, no
# AWS, no LocalStack. One run per target_type × engine shape.

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
  name                = "platform-proxy"
  remote_state_bucket = "stub-bucket"
}

# Default target outputs (aurora-postgresql). Per-run override_data
# replaces this where the engine/identifier must differ.
override_data {
  target = data.terraform_remote_state.target
  values = {
    outputs = {
      master_user_secret_arn              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds-abc"
      master_user_secret_kms_key_arn      = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
      security_group_id                   = "sg-0123456789abcdef0"
      db_subnet_ids                       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      vpc_id                              = "vpc-0123456789abcdef0"
      engine                              = "aurora-postgresql"
      iam_database_authentication_enabled = false
    }
  }
}

run "rds_instance_postgres" {
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
    condition     = aws_db_proxy.this.engine_family == "POSTGRESQL"
    error_message = "engine 'postgres' must derive engine_family POSTGRESQL"
  }

  assert {
    condition     = aws_db_proxy_target.this.db_instance_identifier == "platform-db"
    error_message = "rds-instance target must set db_instance_identifier"
  }

  assert {
    condition     = aws_db_proxy_target.this.db_cluster_identifier == null
    error_message = "rds-instance target must leave db_cluster_identifier null"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.to_db.from_port == 5432
    error_message = "postgres default listener port must be 5432 on the proxy→DB egress rule"
  }

  assert {
    condition     = length(aws_db_proxy_endpoint.read_only) == 0
    error_message = "no read-only endpoint by default"
  }

  assert {
    condition     = one(aws_db_proxy.this.auth).secret_arn == "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds-abc"
    error_message = "auth.secret_arn must be the master secret read from remote state"
  }
}

run "aurora_cluster_postgres" {
  command = plan

  variables {
    target_type       = "aurora-cluster"
    target_identifier = "platform-aurora"
  }

  assert {
    condition     = aws_db_proxy.this.engine_family == "POSTGRESQL"
    error_message = "engine 'aurora-postgresql' must derive engine_family POSTGRESQL"
  }

  assert {
    condition     = aws_db_proxy_target.this.db_cluster_identifier == "platform-aurora"
    error_message = "aurora-cluster target must set db_cluster_identifier"
  }

  assert {
    condition     = aws_db_proxy_target.this.db_instance_identifier == null
    error_message = "aurora-cluster target must leave db_instance_identifier null"
  }

  assert {
    condition     = aws_security_group.proxy.vpc_id == "vpc-0123456789abcdef0"
    error_message = "proxy SG must be placed in the target VPC from remote state"
  }
}

run "serverless_postgres" {
  command = plan

  variables {
    target_type       = "serverless"
    target_identifier = "platform-rds"
  }

  assert {
    condition     = aws_db_proxy_target.this.db_cluster_identifier == "platform-rds"
    error_message = "serverless target must set db_cluster_identifier (Aurora cluster under the hood)"
  }

  assert {
    condition     = aws_db_proxy.this.require_tls == true
    error_message = "require_tls must default to true"
  }
}
