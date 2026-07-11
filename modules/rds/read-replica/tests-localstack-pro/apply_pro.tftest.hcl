# LocalStack PRO apply suite (IMPL-0013 Phase 6 / Q3, Q4-b).
#
# OFF BY DEFAULT. Reader instances are Aurora (a real embedded
# PostgreSQL, Pro-only) AND the apply must bridge the cluster's remote
# state through a real S3-object fixture (override_data can't reference a
# prior apply's outputs). Both are Pro-tier, so this suite lives in its
# own tests-localstack-pro/ directory and runs ONLY via the dedicated
# recipe:
#
#   just tf test-localstack-pro rds/read-replica
#
# which requires a running LocalStack **Pro** container on :4566 (a
# LOCALSTACK_AUTH_TOKEN in the environment). The default
# `just tf test-localstack rds/read-replica` runs only the Community-safe
# plan_smoke in ../tests-localstack/.
#
# Strategy (Q4-b): the setup fixture instantiates the ACTUAL
# modules/rds/cluster module (exercising the real cluster ↔ read-replica
# composition end-to-end) and writes its outputs to S3 as the stub
# cluster state at the read-replica's key. apply_replicas then reads that
# state for real via data.terraform_remote_state.rds_cluster and attaches
# the readers.
#
# Required env vars (the `just tf test-localstack-pro` recipe wires
# these automatically):
#
#   AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566
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
  region              = "us-east-1"
  remote_state_bucket = "tftest-rr-state"
  cluster_identifier  = "tftest-rr-cluster"
  identifier_prefix   = "tftest-rr"
}

# Stand up the real cluster module (VPC + stub VPC state + cluster +
# writer) and write the cluster's outputs to S3 as the stub cluster
# state at the read-replica's key.
run "setup" {
  command = apply

  variables {
    region              = "us-east-1"
    remote_state_bucket = "tftest-rr-state"
    vpc_name            = "tftest-rr-vpc"
    cluster_identifier  = "tftest-rr-cluster"
  }

  module {
    source = "./tests-localstack-pro/fixtures/cluster"
  }
}

# Apply the readers; they read the cluster's stub state from S3.
run "apply_replicas" {
  command = apply

  variables {
    replicas = {
      r1 = { instance_class = "db.t3.medium" }
      r2 = { instance_class = "db.t3.medium", promotion_tier = 10 }
    }
  }

  assert {
    condition     = length(aws_rds_cluster_instance.replica) == 2
    error_message = "Two replicas entries must apply exactly two reader instances against LocalStack Pro"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["r1"].identifier == "tftest-rr-replica-r1"
    error_message = "reader r1 identifier must compose from identifier_prefix + key"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["r1"].cluster_identifier == "tftest-rr-cluster"
    error_message = "readers must attach to the cluster identifier read from the fixture's stub state"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["r1"].engine == "aurora-postgresql"
    error_message = "reader engine must be inherited from the cluster remote state"
  }

  assert {
    condition     = aws_rds_cluster_instance.replica["r2"].promotion_tier == 10
    error_message = "per-reader promotion_tier override must plumb through on apply"
  }

  assert {
    condition     = length(output.replica_identifiers) == 2 && length(output.replica_endpoints) == 2
    error_message = "both output maps must be keyed by all replicas keys"
  }

  assert {
    condition     = length(aws_rds_cluster_instance.replica["r1"].endpoint) > 0
    error_message = "LocalStack Pro must populate a per-reader endpoint on apply"
  }
}
