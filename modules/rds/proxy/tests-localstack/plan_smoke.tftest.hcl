# Community-safe plan-only smoke (IMPL-0010 Phase 10 / Q7).
#
# RDS Proxy is LocalStack **Pro-only** (native RDS provider v4.4+,
# CreateDBProxyEndpoint v4.5+), so the DEFAULT tests-localstack suite is
# plan-only: it confirms the proxy module plans against the LocalStack
# provider endpoints with remote state stubbed via override_data,
# WITHOUT applying the Pro-only proxy resources. It therefore passes on
# LocalStack Community — and even with no LocalStack at all, since a
# plan with overridden data makes no API calls.
#
# The full apply lives in ../tests-localstack-pro/apply_pro.tftest.hcl,
# gated behind `just tf test-localstack-pro rds/proxy` (off by default).
#
# The `just tf test-localstack rds/proxy` recipe wires
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
  name                = "tftest-proxy"
  remote_state_bucket = "tftest-proxy-state"
  target_type         = "serverless"
  target_identifier   = "tftest-rds"
}

override_data {
  target = data.terraform_remote_state.target
  values = {
    outputs = {
      master_user_secret_arn              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:tftest-rds"
      master_user_secret_kms_key_arn      = "arn:aws:kms:us-east-1:000000000000:key/byo-1"
      security_group_id                   = "sg-0123456789abcdef0"
      db_subnet_ids                       = ["subnet-aaa", "subnet-bbb"]
      vpc_id                              = "vpc-0123456789abcdef0"
      engine                              = "aurora-postgresql"
      iam_database_authentication_enabled = false
    }
  }
}

run "plan_smoke" {
  command = plan

  assert {
    condition     = aws_db_proxy.this.engine_family == "POSTGRESQL"
    error_message = "proxy must plan engine_family POSTGRESQL against the LocalStack provider"
  }

  assert {
    condition     = aws_db_proxy_target.this.db_cluster_identifier == "tftest-rds"
    error_message = "proxy target must reference the serverless cluster identifier"
  }

  assert {
    condition     = length(aws_db_proxy_endpoint.read_only) == 0
    error_message = "no read-only endpoint by default"
  }
}
