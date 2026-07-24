# Storage autoscaling surface (IMPL-0011 Phase 8, Q3).
#
# max_allocated_storage default null = autoscaling off. When set it must
# be >= allocated_storage (precondition). Q3=a: no lifecycle.ignore_changes
# is added (the provider suppresses the allocated_storage diff for
# autoscaling-driven growth), so the config plans cleanly with the ceiling
# set and deliberate resizes still apply. The empirical drift confirmation
# lives in tests-localstack/FINDINGS.md (Pro apply).

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

run "autoscaling_off_by_default" {
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
    condition     = aws_db_instance.this.max_allocated_storage == null
    error_message = "Null max_allocated_storage must leave autoscaling off (the attribute stays null when unset at plan)"
  }
}

run "autoscaling_ceiling_set" {
  command = plan

  variables {
    allocated_storage     = 20
    max_allocated_storage = 100
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
    condition     = aws_db_instance.this.max_allocated_storage == 100
    error_message = "max_allocated_storage must pass through to the instance when set >= allocated_storage"
  }

  assert {
    condition     = aws_db_instance.this.allocated_storage == 20
    error_message = "allocated_storage must remain the configured floor (no ignore_changes suppressing it)"
  }
}

run "ceiling_below_floor_rejected" {
  command = plan

  variables {
    allocated_storage     = 100
    max_allocated_storage = 50
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

  expect_failures = [
    aws_db_instance.this,
  ]
}
