# Managed master secret rotation surface (IMPL-0017 Phase 4).
#
# Plan-time coverage of secret_rotation.tf's count gate + schedule wiring
# (OQ 1a): present at the 90-day default, tracks an explicit override,
# absent on the null opt-out, and silently omitted under
# manage_master_user_password = false (IAM auth on, so the guardrail
# precondition passes). This suite is the gate for the rotation surface —
# LocalStack Pro cannot apply the resource (Phase 1 parity gap, OQ 2a).

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region                    = "us-east-1"
  remote_state_bucket       = "stub-bucket"
  vpc_name                  = "libtftest-vpc"
  identifier_prefix         = "platform-rds"
  engine                    = "postgres"
  instance_class            = "db.t4g.medium"
  allocated_storage         = 20
  final_snapshot_identifier = "platform-rds-final-test"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "default_rotation_90_days" {
  command = plan

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id                 = "vpc-0123456789abcdef0"
        private_subnet_ids     = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        private_eks_subnet_ids = ["subnet-eks-aaa", "subnet-eks-bbb", "subnet-eks-ccc"]
        public_subnet_ids      = ["subnet-pub-aaa", "subnet-pub-bbb", "subnet-pub-ccc"]
        vpc_cidr_block         = "10.0.0.0/16"
        availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
        nat_gateway_ids        = ["nat-0123456789abcdef0"]
        route_table_ids        = ["rtb-public0", "rtb-private0"]
        internet_gateway_id    = "igw-0123456789abcdef0"
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_rotation.master) == 1
    error_message = "Rotation resource must be present under defaults (manage = true, 90-day default)"
  }

  assert {
    condition     = aws_secretsmanager_secret_rotation.master[0].rotation_rules[0].automatically_after_days == 90
    error_message = "Rotation cadence must default to 90 days (INV-0008 quarterly default)"
  }

  assert {
    condition     = aws_secretsmanager_secret_rotation.master[0].rotate_immediately == false
    error_message = "rotate_immediately must be false — adopting the schedule must not trigger an out-of-band rotation"
  }
}

run "explicit_days_tracked" {
  command = plan

  variables {
    master_secret_rotation_days = 30
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id                 = "vpc-0123456789abcdef0"
        private_subnet_ids     = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        private_eks_subnet_ids = ["subnet-eks-aaa", "subnet-eks-bbb", "subnet-eks-ccc"]
        public_subnet_ids      = ["subnet-pub-aaa", "subnet-pub-bbb", "subnet-pub-ccc"]
        vpc_cidr_block         = "10.0.0.0/16"
        availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
        nat_gateway_ids        = ["nat-0123456789abcdef0"]
        route_table_ids        = ["rtb-public0", "rtb-private0"]
        internet_gateway_id    = "igw-0123456789abcdef0"
      }
    }
  }

  assert {
    condition     = aws_secretsmanager_secret_rotation.master[0].rotation_rules[0].automatically_after_days == 30
    error_message = "Rotation cadence must track an explicit master_secret_rotation_days override"
  }
}

run "null_opts_out" {
  command = plan

  variables {
    master_secret_rotation_days = null
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id                 = "vpc-0123456789abcdef0"
        private_subnet_ids     = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        private_eks_subnet_ids = ["subnet-eks-aaa", "subnet-eks-bbb", "subnet-eks-ccc"]
        public_subnet_ids      = ["subnet-pub-aaa", "subnet-pub-bbb", "subnet-pub-ccc"]
        vpc_cidr_block         = "10.0.0.0/16"
        availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
        nat_gateway_ids        = ["nat-0123456789abcdef0"]
        route_table_ids        = ["rtb-public0", "rtb-private0"]
        internet_gateway_id    = "igw-0123456789abcdef0"
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_rotation.master) == 0
    error_message = "Rotation resource must be absent when master_secret_rotation_days = null (leave AWS's schedule alone)"
  }
}

run "manage_false_omits_rotation" {
  command = plan

  variables {
    manage_master_user_password         = false
    iam_database_authentication_enabled = true
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id                 = "vpc-0123456789abcdef0"
        private_subnet_ids     = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        private_eks_subnet_ids = ["subnet-eks-aaa", "subnet-eks-bbb", "subnet-eks-ccc"]
        public_subnet_ids      = ["subnet-pub-aaa", "subnet-pub-bbb", "subnet-pub-ccc"]
        vpc_cidr_block         = "10.0.0.0/16"
        availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
        nat_gateway_ids        = ["nat-0123456789abcdef0"]
        route_table_ids        = ["rtb-public0", "rtb-private0"]
        internet_gateway_id    = "igw-0123456789abcdef0"
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_rotation.master) == 0
    error_message = "Rotation resource must be silently omitted when manage_master_user_password = false (OQ 1a — no managed secret to schedule)"
  }
}
