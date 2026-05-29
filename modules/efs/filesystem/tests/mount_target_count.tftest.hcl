# Mount target count tracks private_subnet_ids cardinality.
#
# Three-subnet VPC → three mount targets. Single-subnet VPC →
# one mount target (the cluster-on-single-AZ degenerate case).

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

run "three_subnets" {
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
    condition     = length(aws_efs_mount_target.this) == 3
    error_message = "Three private subnets must produce exactly three mount targets"
  }

  assert {
    condition     = aws_efs_mount_target.this["subnet-aaa"].subnet_id == "subnet-aaa"
    error_message = "Mount target map key must equal subnet_id (for_each over toset)"
  }
}

run "single_subnet" {
  command = plan

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-only-one"]
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
    condition     = length(aws_efs_mount_target.this) == 1
    error_message = "Single-subnet VPC must produce exactly one mount target"
  }
}
