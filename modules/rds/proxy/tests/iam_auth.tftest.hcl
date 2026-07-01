# IAM auth mapping per IMPL-0010 Phase 9. require_iam_auth maps to the
# proxy auth.iam_auth REQUIRED/DISABLED, gated by the target's IAM-auth
# state (V4). Remote state stubbed via override_data (Q2-a).

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

run "iam_auth_disabled_by_default" {
  command = plan

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

  assert {
    condition     = one(aws_db_proxy.this.auth).iam_auth == "DISABLED"
    error_message = "iam_auth must default to DISABLED"
  }
}

run "iam_auth_required_when_enabled" {
  command = plan

  variables {
    require_iam_auth = true
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
        iam_database_authentication_enabled = true
      }
    }
  }

  assert {
    condition     = one(aws_db_proxy.this.auth).iam_auth == "REQUIRED"
    error_message = "require_iam_auth = true (with target IAM auth on) must map iam_auth to REQUIRED"
  }
}
