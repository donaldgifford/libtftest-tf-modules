# Read-only endpoint gating per IMPL-0010 Phase 9 (DESIGN-0010 Q5-a).
# The endpoint exists iff create_read_only_endpoint AND an Aurora target.
# Remote state stubbed via override_data (Q2-a).

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
  target_type         = "aurora-cluster"
  target_identifier   = "platform-aurora"
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
      engine                              = "aurora-postgresql"
      iam_database_authentication_enabled = false
    }
  }
}

run "aurora_with_flag_creates_endpoint" {
  command = plan

  variables {
    create_read_only_endpoint = true
  }

  assert {
    condition     = length(aws_db_proxy_endpoint.read_only) == 1
    error_message = "Aurora target + create_read_only_endpoint must plan exactly one endpoint"
  }

  assert {
    condition     = aws_db_proxy_endpoint.read_only[0].target_role == "READ_ONLY"
    error_message = "the endpoint target_role must be READ_ONLY"
  }

  assert {
    condition     = aws_db_proxy_endpoint.read_only[0].db_proxy_endpoint_name == "platform-proxy-read-only"
    error_message = "the endpoint name must be <proxy name>-read-only"
  }
}

run "aurora_without_flag_no_endpoint" {
  command = plan

  assert {
    condition     = length(aws_db_proxy_endpoint.read_only) == 0
    error_message = "no read-only endpoint without the flag"
  }
}

run "serverless_with_flag_creates_endpoint" {
  command = plan

  variables {
    target_type               = "serverless"
    target_identifier         = "platform-rds"
    create_read_only_endpoint = true
  }

  assert {
    condition     = length(aws_db_proxy_endpoint.read_only) == 1
    error_message = "serverless (Aurora) target + flag must plan one endpoint"
  }
}
