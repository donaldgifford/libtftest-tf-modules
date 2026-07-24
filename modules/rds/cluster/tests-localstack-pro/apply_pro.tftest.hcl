# LocalStack PRO apply suite (IMPL-0012 Phase 10 / Q5-b).
#
# OFF BY DEFAULT. Aurora provisioned clusters reliably need LocalStack
# **Pro**'s native RDS provider (Community's mock RDS does not boot the
# embedded PostgreSQL an Aurora cluster instance requires), so — like
# modules/rds/proxy — this apply suite lives in its own
# tests-localstack-pro/ directory and runs ONLY via the dedicated recipe:
#
#   just tf test-localstack-pro rds/cluster
#
# which requires a running LocalStack **Pro** container on :4566 (a
# LOCALSTACK_AUTH_TOKEN in the environment). The default
# `just tf test-localstack rds/cluster` runs only the Community-safe
# plan_smoke in ../tests-localstack/.
#
# Strategy (remote-state composition): the setup fixture builds a VPC +
# 3 private subnets and writes a stub VPC state file to S3 at the
# module's expected key. The cluster module then applies and reads that
# state for real via data.terraform_remote_state.vpc — the same S3-stub
# bridge the serverless + proxy apply suites use. (override_data cannot
# reference prior-run outputs, so the S3 round-trip is the bridge.)
#
# Required env vars (the `just tf test-localstack-pro` recipe wires these
# automatically):
#
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1

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
  remote_state_bucket       = "tftest-rds-cluster-state"
  vpc_name                  = "tftest-rds-cluster-vpc"
  identifier_prefix         = "tftest-rds"
  engine                    = "aurora-postgresql"
  instance_class            = "db.t3.medium"
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

# Default-config apply against LocalStack Pro (engine = aurora-postgresql).
# Exercises module-managed KMS, subnet group, security group, both
# parameter groups, the provisioned cluster (NO serverless scaling block),
# and the concrete-class writer instance.
run "apply_default" {
  command = apply

  # Pin the apply to Aurora PostgreSQL 16 — the version verified against
  # LocalStack Pro 2026.6.0 (see FINDINGS.md). The module default is major
  # 18 (Aurora PG 18 GA'd 2026-06-11), but that is newer than this
  # LocalStack image's engine catalog. Bump this pin once a LocalStack
  # image serving Aurora PG 18 is available.
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
    condition     = aws_db_subnet_group.this.name == "tftest-rds-rds-cluster"
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
    condition     = length(aws_rds_cluster.this.serverlessv2_scaling_configuration) == 0
    error_message = "provisioned cluster must NOT apply a serverlessv2_scaling_configuration block"
  }

  assert {
    condition     = length(aws_rds_cluster_instance.writer.id) > 0
    error_message = "LocalStack RDS must populate writer instance id"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.t3.medium"
    error_message = "LocalStack RDS must accept the concrete writer instance_class (var.instance_class)"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.identifier == "tftest-rds-1"
    error_message = "writer identifier must be <identifier_prefix>-1"
  }
}

# Plan-only MySQL coverage — endpoint resolution + plan-time validation
# without a second apply (cheaper than a full apply; catches
# engine-divergent plan-time gaps).
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
