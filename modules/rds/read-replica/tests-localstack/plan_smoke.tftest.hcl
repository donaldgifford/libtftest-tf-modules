# Community-safe plan-only smoke (IMPL-0013 Phase 6 / Q3).
#
# The read-replica apply needs a real Aurora cluster to attach to AND a
# real cross-state bridge (the reader reads the cluster's state via
# data.terraform_remote_state) — both Pro-tier. So — following the
# modules/rds/proxy two-tier layout — the DEFAULT tests-localstack suite
# is plan-only: it confirms the readers plan against the LocalStack
# provider endpoints with the cluster remote state stubbed via
# override_data, WITHOUT applying anything. It therefore passes on
# LocalStack Community — and even with no LocalStack at all, since a plan
# with overridden data makes no API calls.
#
# The full apply lives in ../tests-localstack-pro/apply_pro.tftest.hcl,
# gated behind `just tf test-localstack-pro rds/read-replica` (off by
# default).
#
# The `just tf test-localstack rds/read-replica` recipe wires
# AWS_ENDPOINT_URL/key/secret/region automatically.

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
  region              = "us-east-1"
  remote_state_bucket = "tftest-rr-state"
  cluster_identifier  = "tftest-rr-cluster"
  identifier_prefix   = "tftest-rr"
  replicas = {
    r1 = { instance_class = "db.r6g.large" }
  }
}

override_data {
  target = data.terraform_remote_state.rds_cluster
  values = {
    outputs = {
      cluster_identifier      = "tftest-rr-cluster"
      engine                  = "aurora-postgresql"
      engine_version_actual   = "16.4"
      db_subnet_group_name    = "tftest-rr-cluster-rds-cluster"
      db_parameter_group_name = "tftest-rr-cluster-instance-20260101"
    }
  }
}

run "plan_smoke" {
  command = plan

  assert {
    condition     = length(aws_rds_cluster_instance.replica) == 1
    error_message = "read-replica must plan exactly one reader against the LocalStack provider"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["r1"].identifier == "tftest-rr-replica-r1"
    error_message = "reader identifier must compose from identifier_prefix + key"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["r1"].cluster_identifier == "tftest-rr-cluster"
    error_message = "reader must attach to the cluster_identifier read from the (stubbed) cluster remote state"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["r1"].engine == "aurora-postgresql"
    error_message = "reader engine must be inherited from the cluster remote state"
  }
}
