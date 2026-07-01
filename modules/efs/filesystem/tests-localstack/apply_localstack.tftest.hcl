# Apply against LocalStack — gap-discovery mode per RFC-0001 / IMPL-0008 Phase 10.
#
# This module's AWS API surface (EFS filesystem, EFS mount target, EFS
# access point, EFS backup policy + the supporting KMS, VPC, IAM) was
# probed against LocalStack Community 3.8.1 on 2026-05-29. Outcome
# captured in FINDINGS.md: `efs:CreateFileSystem` returns 501 with
# "API for service 'efs' not yet implemented or pro feature" — the
# filesystem ARE the module's reason to exist, so a partial-apply of
# this module isn't meaningful.
#
# Per IMPL-0008 Phase 10 / IMPL-0005 Phase 9 fall-back pattern: the
# apply run blocks are preserved below as commented code so future
# LocalStack releases (or Pro 2026.5.0 with a license at run time)
# can re-enable them by uncomment-only. The active suite is the
# `plan_smoke` run below: a plan against LocalStack proves the module
# is wireable end-to-end (provider endpoint resolution, STS reach,
# remote-state reads through the S3 stub state files, every resource
# validates without 501 at plan time — they only 501 on create).
#
# Required env vars (the `just tf test-localstack` recipe wires these
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
    backup = "http://localhost:4566"
    ec2    = "http://localhost:4566"
    efs    = "http://localhost:4566"
    iam    = "http://localhost:4566"
    kms    = "http://localhost:4566"
    s3     = "http://s3.localhost.localstack.cloud:4566"
    sts    = "http://localhost:4566"
  }
}

variables {
  region              = "us-east-1"
  remote_state_bucket = "tftest-efs-filesystem-state"
  vpc_name            = "tftest-efs-filesystem-vpc"
  cluster_name        = "tftest-efs-filesystem-eks"
  identifier_prefix   = "tftest-efs"
  tags = {
    Environment = "test"
    ManagedBy   = "libtftest"
  }
}

# Setup: VPC + 3 private subnets + standalone node-SG stub + S3 bucket
# holding TWO stub state files (VPC + EKS) at the conventional keys.
# Applied first so the module's data sources resolve.
run "setup" {
  command = apply

  variables {
    remote_state_bucket = var.remote_state_bucket
    vpc_name            = var.vpc_name
    cluster_name        = var.cluster_name
    region              = var.region
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

# Plan-only smoke against LocalStack endpoints. Validates that:
#
#   * The provider resolves through LocalStack (EC2 + S3 reads for
#     remote state succeed against the setup fixture's stub state).
#   * Every resource in the module validates at plan time against
#     LocalStack's AWS API surface (EFS resources only 501 on
#     CreateFileSystem / CreateMountTarget / CreateAccessPoint —
#     plan time is fine).
#
# This run keeps passing as the module's surface evolves; a real
# apply assertion against the EFS resources requires LocalStack Pro
# (or a future Community release that lands the EFS API). See
# FINDINGS.md §Finding #1.
run "plan_smoke" {
  command = plan

  assert {
    condition     = aws_efs_file_system.this.encrypted == true
    error_message = "Plan must resolve aws_efs_file_system.this against LocalStack endpoints with encrypted = true"
  }

  assert {
    condition     = aws_efs_file_system.this.creation_token == "tftest-efs"
    error_message = "Plan must resolve creation_token = var.identifier_prefix"
  }

  assert {
    condition     = length(aws_efs_mount_target.this) == 3
    error_message = "Plan must wire 3 mount targets (one per private subnet from the fixture)"
  }

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "Plan must wire exactly 1 module-managed KMS key"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_nodes.from_port == 2049
    error_message = "Plan must wire NFS ingress on port 2049"
  }
}

# Apply run — active as of the Pro 2026.6.0 sweep (2026-07-01): EFS is
# served by LocalStack Pro, so this applies the real filesystem + mount
# targets + access point. See FINDINGS.md §Finding #1.

run "apply_default" {
  command = apply

  variables {
    access_points = {
      grafana = {
        posix_user = {
          uid = 472
          gid = 472
        }
        root_directory = {
          path = "/grafana"
          creation_info = {
            owner_uid   = 472
            owner_gid   = 472
            permissions = "0755"
          }
        }
      }
    }
  }

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "Module-managed KMS must produce 1 key against LocalStack"
  }

  assert {
    condition     = length(aws_efs_file_system.this.id) > 0
    error_message = "LocalStack EFS must populate filesystem id"
  }

  assert {
    condition     = length(aws_efs_mount_target.this) == 3
    error_message = "LocalStack EFS must create exactly three mount targets"
  }

  assert {
    condition     = length(aws_efs_access_point.this) == 1
    error_message = "LocalStack EFS must create exactly one access point"
  }

  assert {
    condition     = aws_efs_access_point.this["grafana"].posix_user[0].uid == 472
    error_message = "LocalStack EFS must honor access-point posix_user.uid"
  }
}

# apply_backup_enabled — STILL BLOCKED on Pro 2026.6.0 (probed 2026-07-01):
# aws_efs_backup_policy hits `PutBackupPolicy => 501 InternalFailure: The
# put_backup_policy action has not been implemented`. Kept commented per the
# RFC-0001 fall-back; re-enable when LocalStack implements PutBackupPolicy.
# See FINDINGS.md §Finding #2.
#
# run "apply_backup_enabled" {
#   command = apply
#
#   variables {
#     backup_policy_enabled = true
#   }
#
#   assert {
#     condition     = length(aws_efs_backup_policy.this) == 1
#     error_message = "LocalStack must create one backup policy when opted in"
#   }
#
#   assert {
#     condition     = aws_efs_backup_policy.this[0].backup_policy[0].status == "ENABLED"
#     error_message = "Backup policy status must equal ENABLED against LocalStack"
#   }
# }
