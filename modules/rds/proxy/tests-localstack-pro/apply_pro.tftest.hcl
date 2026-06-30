# LocalStack PRO apply suite (IMPL-0010 Phase 10 / Q7).
#
# OFF BY DEFAULT. RDS Proxy is LocalStack Pro-only (native RDS provider
# v4.4+, CreateDBProxyEndpoint v4.5+), so this suite lives in its own
# tests-localstack-pro/ directory and runs ONLY via the dedicated
# recipe:
#
#   just tf test-localstack-pro rds/proxy
#
# which requires a running LocalStack **Pro** container on :4566 (a
# LOCALSTACK_AUTH_TOKEN in the environment). The default
# `just tf test-localstack rds/proxy` runs only the Community-safe
# plan_smoke in ../tests-localstack/.
#
# Strategy (DESIGN-0010 Q3 — remote-state composition): the setup
# fixture applies a minimal Aurora target AND writes a stub state file
# to S3 at the proxy's expected key. The proxy then applies and reads
# that state for real via data.terraform_remote_state.target — the same
# S3-stub bridge the serverless apply suite uses. (override_data cannot
# reference prior-run outputs, so the S3 round-trip is the bridge.)

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
  name                = "tftest-proxy"
  remote_state_bucket = "tftest-proxy-state"
  target_type         = "serverless"
  target_identifier   = "tftest-rds"
}

# Stand up the Aurora target + write its stub state to S3 at the
# proxy's remote-state key.
run "setup" {
  command = apply

  variables {
    identifier          = "tftest-rds"
    region              = "us-east-1"
    remote_state_bucket = "tftest-proxy-state"
  }

  module {
    source = "./tests-localstack-pro/fixtures/db"
  }
}

# Apply the proxy; it reads the fixture's stub state from S3.
run "proxy_apply" {
  command = apply

  assert {
    condition     = aws_db_proxy.this.engine_family == "POSTGRESQL"
    error_message = "applied proxy must have engine_family POSTGRESQL"
  }

  assert {
    condition     = length(aws_db_proxy.this.arn) > 0
    error_message = "LocalStack Pro must populate the proxy ARN on apply"
  }

  assert {
    condition     = aws_db_proxy_target.this.db_cluster_identifier == "tftest-rds"
    error_message = "proxy target must attach the applied Aurora cluster"
  }

  assert {
    condition     = length(aws_db_proxy_default_target_group.this.id) > 0
    error_message = "LocalStack Pro must populate the default target group id"
  }
}

# Apply again with the read-only endpoint enabled (Aurora-only path).
run "proxy_read_only_endpoint" {
  command = apply

  variables {
    create_read_only_endpoint = true
  }

  assert {
    condition     = length(aws_db_proxy_endpoint.read_only) == 1
    error_message = "Aurora target + flag must create a READ_ONLY endpoint on Pro"
  }

  assert {
    condition     = aws_db_proxy_endpoint.read_only[0].target_role == "READ_ONLY"
    error_message = "the endpoint target_role must be READ_ONLY"
  }
}
