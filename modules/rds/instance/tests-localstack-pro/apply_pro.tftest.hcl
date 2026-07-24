# LocalStack PRO apply suite (IMPL-0011 Phase 9 / Q5=b).
#
# OFF BY DEFAULT. A plain aws_db_instance is baseline RDS, but on
# LocalStack Pro the instance boots a real embedded Postgres — so, like
# modules/rds/cluster, this apply suite lives in its own
# tests-localstack-pro/ directory and runs ONLY via the dedicated recipe:
#
#   just tf test-localstack-pro rds/instance
#
# which requires a running LocalStack **Pro** container on :4566 (a
# LOCALSTACK_AUTH_TOKEN in the environment). The default
# `just tf test-localstack rds/instance` runs only the Community-safe
# plan_smoke in ../tests-localstack/.
#
# macOS caveat: the Pro RDS apply needs /var/lib/localstack on a Docker
# NAMED VOLUME, not the lstk host bind mount — Docker Desktop ignores
# chown so the embedded Postgres initdb fails on data-dir ownership. See
# ../tests-localstack/FINDINGS.md.
#
# Strategy (remote-state composition): the setup fixture builds a VPC +
# 3 private subnets and writes a stub VPC state file to S3 at the
# module's expected key. The instance module then applies and reads that
# state for real via data.terraform_remote_state.vpc — the same S3-stub
# bridge the serverless + cluster apply suites use. (override_data cannot
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
  remote_state_bucket       = "tftest-rds-instance-state"
  vpc_name                  = "tftest-rds-instance-vpc"
  identifier_prefix         = "tftest-rds"
  engine                    = "postgres"
  instance_class            = "db.t3.micro"
  allocated_storage         = 20
  final_snapshot_identifier = "tftest-rds-final"

  # The module defaults deletion_protection = true (correct for prod), but
  # `terraform test`'s automatic teardown then cannot DeleteDBInstance —
  # LocalStack Pro enforces deletion protection on a standalone
  # aws_db_instance (InvalidParameterCombination: "Cannot delete protected
  # DB Instance"). Disable it here + skip the final snapshot so the
  # ephemeral test instance is destroyable. See FINDINGS.md.
  deletion_protection = false
  skip_final_snapshot = true

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

# Default-config apply against LocalStack Pro (engine = postgres).
# Exercises module-managed KMS, subnet group, security group, the DB
# parameter group, and the aws_db_instance with its full storage +
# AWS-managed-secret surface.
run "apply_default" {
  command = apply

  # Pin the apply to PostgreSQL 16 — the version verified against
  # LocalStack Pro 2026.6.x (see FINDINGS.md). The module default is major
  # 18 (PG 18 GA'd 2026), but that is newer than this LocalStack image's
  # engine catalog. Bump this pin once a LocalStack image serving PG 18 is
  # available.
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
    condition     = aws_db_subnet_group.this.name == "tftest-rds-rds-instance"
    error_message = "DB subnet group name must compose from identifier_prefix"
  }

  assert {
    condition     = length(aws_db_instance.this.id) > 0
    error_message = "LocalStack RDS must populate the instance id"
  }

  assert {
    condition     = aws_db_instance.this.engine == "postgres"
    error_message = "LocalStack RDS must accept the postgres engine"
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.t3.micro"
    error_message = "LocalStack RDS must accept the concrete instance_class (var.instance_class)"
  }

  assert {
    condition     = aws_db_instance.this.identifier == "tftest-rds"
    error_message = "instance identifier must be var.identifier_prefix"
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "LocalStack RDS instance must be storage_encrypted"
  }
}

# Plan-only MySQL coverage — endpoint resolution + plan-time validation
# without a second apply (cheaper than a full apply; catches
# engine-divergent plan-time gaps).
run "plan_mysql" {
  command = plan

  variables {
    engine = "mysql"
  }

  assert {
    condition     = aws_db_instance.this.engine == "mysql"
    error_message = "Plan must resolve mysql engine against LocalStack endpoints"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "mysql8.4"
    error_message = "MySQL parameter family must resolve to mysql8.4"
  }
}
