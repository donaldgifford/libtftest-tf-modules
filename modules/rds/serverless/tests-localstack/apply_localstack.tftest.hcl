# Apply against LocalStack — gap-discovery mode per RFC-0001.
#
# This file exercises `command = apply` against LocalStack to surface
# what LocalStack actually serves for the Aurora Serverless v2 surface:
# RDS cluster + cluster instance with engine_mode = "provisioned" +
# serverlessv2_scaling_configuration, KMS-backed storage encryption,
# AWS-managed master password via Secrets Manager, and the supporting
# subnet group / security group / parameter groups.
#
# Per IMPL-0007 Q5 / Q7:
#   - Default tier: LocalStack Community.
#   - Pro is also exercised and expected to be tier-agnostic.
#   - One apply_default run (engine = aurora-postgresql).
#   - One plan_mysql run (engine = aurora-mysql) for endpoint-resolution
#     coverage of the MySQL engine without a second apply.
#
# Required env vars (the `just tf test-localstack` recipe wires these
# automatically):
#
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# If apply_default hits a 501/NotImplemented (Aurora Serverless v2 is
# the highest-risk surface for LocalStack), follow the IMPL-0005
# Phase 9 fall-back: comment out the apply, document the gap in
# FINDINGS.md, leave a `plan_smoke` run active.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    kms            = "http://localhost:4566"
    rds            = "http://localhost:4566"
    s3             = "http://s3.localhost.localstack.cloud:4566"
    secretsmanager = "http://localhost:4566"
    sts            = "http://localhost:4566"
  }
}

variables {
  region                    = "us-east-1"
  remote_state_bucket       = "tftest-rds-serverless-state"
  vpc_name                  = "tftest-rds-serverless-vpc"
  identifier_prefix         = "tftest-rds"
  engine                    = "aurora-postgresql"
  min_acu                   = 0.5
  max_acu                   = 1
  final_snapshot_identifier = "tftest-rds-final"
  tags = {
    Environment = "test"
    ManagedBy   = "libtftest"
  }
}

# Setup: the shared vpc-lookup-faithful reference VPC (three-tier
# Network-tagged topology + full nine-output remote-state contract),
# seeded into S3 at the conventional key. Applied first so the module's
# data.terraform_remote_state.vpc resolves. See test/fixtures/reference-vpc.
run "setup" {
  command = apply

  variables {
    remote_state_bucket = var.remote_state_bucket
    vpc_name            = var.vpc_name
    region              = var.region
  }

  module {
    source = "../../../test/fixtures/reference-vpc"
  }
}

# Default-config apply against LocalStack (engine = aurora-postgresql
# per Q5). Exercises module-managed KMS, subnet group, security group,
# both parameter groups, the Serverless v2 cluster, and the
# db.serverless cluster instance.
run "apply_default" {
  command = apply

  # Pin the apply to Aurora PostgreSQL 16 — the version verified against
  # LocalStack Pro 2026.6.0 (see FINDINGS.md). The module default was
  # bumped to major 18 (Aurora PG 18 GA'd 2026-06-11), but that is newer
  # than this LocalStack image's engine catalog. Bump this pin once a
  # LocalStack image serving Aurora PG 18 is available.
  variables {
    engine_version = "16"
  }

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "Module-managed KMS must produce 1 key against LocalStack"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 1
    error_message = "Module-managed KMS must produce 1 alias against LocalStack"
  }

  assert {
    condition     = aws_db_subnet_group.this.name == "tftest-rds-rds-serverless"
    error_message = "DB subnet group name must compose from identifier_prefix"
  }

  assert {
    condition     = length(aws_rds_cluster.this.id) > 0
    error_message = "LocalStack RDS must populate cluster id"
  }

  assert {
    condition     = aws_rds_cluster.this.engine == "aurora-postgresql"
    error_message = "LocalStack RDS must accept aurora-postgresql engine"
  }

  assert {
    condition     = aws_rds_cluster.this.engine_mode == "provisioned"
    error_message = "engine_mode must be \"provisioned\" against LocalStack"
  }

  assert {
    condition     = length(aws_rds_cluster.this.serverlessv2_scaling_configuration) == 1
    error_message = "LocalStack RDS must accept serverlessv2_scaling_configuration block"
  }

  assert {
    condition     = length(aws_rds_cluster_instance.this.id) > 0
    error_message = "LocalStack RDS must populate cluster instance id"
  }

  assert {
    condition     = aws_rds_cluster_instance.this.instance_class == "db.serverless"
    error_message = "LocalStack RDS must accept db.serverless instance class"
  }
}

# Plan-only MySQL coverage — endpoint resolution + plan-time
# validation without a second apply (per Q5 — cheaper than full apply,
# catches engine-divergent plan-time gaps).
run "plan_mysql" {
  command = plan

  variables {
    engine = "aurora-mysql"
  }

  assert {
    condition     = aws_rds_cluster.this.engine == "aurora-mysql"
    error_message = "Plan must resolve aurora-mysql engine against LocalStack endpoints"
  }

  assert {
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-mysql8.0"
    error_message = "MySQL parameter family must resolve to aurora-mysql8.0"
  }
}
