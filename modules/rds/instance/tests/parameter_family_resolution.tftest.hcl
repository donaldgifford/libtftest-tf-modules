# Parameter-family resolution (IMPL-0011 Phase 8).
#
# local.resolved_parameter_family = coalesce(var.parameter_family, static
# lookup keyed by engine + normalized major). Postgres normalizes to the
# leading major (18/17/16); MySQL keeps major.minor (8.4/8.0). An explicit
# var.parameter_family always wins.

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
  instance_class            = "db.t4g.medium"
  allocated_storage         = 20
  final_snapshot_identifier = "platform-rds-final-test"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "postgres_default_major" {
  command = plan

  variables {
    engine         = "postgres"
    engine_version = null
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
    condition     = aws_db_parameter_group.this.family == "postgres18"
    error_message = "Null engine_version must resolve to the default major (postgres18)"
  }
}

run "postgres_pinned_16" {
  command = plan

  variables {
    engine         = "postgres"
    engine_version = "16.4"
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
    condition     = aws_db_parameter_group.this.family == "postgres16"
    error_message = "engine_version 16.4 must normalize to the leading major -> postgres16"
  }
}

run "mysql_pinned_80" {
  command = plan

  variables {
    engine         = "mysql"
    engine_version = "8.0"
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
    condition     = aws_db_parameter_group.this.family == "mysql8.0"
    error_message = "MySQL engine_version 8.0 must keep major.minor -> mysql8.0"
  }
}

run "explicit_family_override_wins" {
  command = plan

  variables {
    engine           = "postgres"
    engine_version   = "16"
    parameter_family = "postgres17"
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
    condition     = aws_db_parameter_group.this.family == "postgres17"
    error_message = "An explicit var.parameter_family must win over the engine+version lookup"
  }
}
