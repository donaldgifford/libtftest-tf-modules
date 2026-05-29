# Module-managed KMS shape.
#
# var.kms_key_arn = null gates the count, so exactly one aws_kms_key +
# aws_kms_alias are planned. local.kms_key_arn is apply-time-only in
# this mode (the managed key's ARN is unknown at plan), so we cannot
# assert on aws_efs_file_system.this.kms_key_id here.

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
  kms_key_arn         = null
}

run "plan_managed_kms" {
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
    condition     = length(aws_kms_key.this) == 1
    error_message = "Module-managed mode must plan exactly one aws_kms_key resource"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 1
    error_message = "Module-managed mode must plan exactly one aws_kms_alias resource"
  }

  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation == true
    error_message = "Module-managed key must have rotation enabled"
  }

  assert {
    condition     = aws_kms_key.this[0].deletion_window_in_days == 30
    error_message = "Module-managed key must use a 30-day deletion window"
  }

  assert {
    condition     = aws_kms_alias.this[0].name == "alias/platform-efs-efs"
    error_message = "Module-managed alias must be named alias/<identifier_prefix>-efs"
  }
}
