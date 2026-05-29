# Backup policy gate per var.backup_policy_enabled.
#
# Default (false) → zero aws_efs_backup_policy resources.
# Opt-in (true) → one aws_efs_backup_policy with status = "ENABLED".

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
  remote_state_bucket = "stub-bucket"
  vpc_name            = "libtftest-vpc"
  cluster_name        = "libtftest-eks"
  identifier_prefix   = "platform-efs"
  kms_key_arn         = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "backup_disabled_by_default" {
  command = plan

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        node_security_group_id = "sg-node1234567890"
      }
    }
  }

  assert {
    condition     = length(aws_efs_backup_policy.this) == 0
    error_message = "backup_policy_enabled default false must plan zero backup policy resources"
  }
}

run "backup_enabled" {
  command = plan

  variables {
    backup_policy_enabled = true
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        node_security_group_id = "sg-node1234567890"
      }
    }
  }

  assert {
    condition     = length(aws_efs_backup_policy.this) == 1
    error_message = "backup_policy_enabled = true must plan exactly one backup policy resource"
  }

  assert {
    condition     = aws_efs_backup_policy.this[0].backup_policy[0].status == "ENABLED"
    error_message = "Backup policy status must equal ENABLED"
  }
}
