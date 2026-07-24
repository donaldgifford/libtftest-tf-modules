# Community-safe plan-only smoke (IMPL-0011 Phase 9 / Q5=b).
#
# A plain aws_db_instance is baseline RDS (feature-supported on both
# tiers), but there is no token-free Community LocalStack in 2026.6.x and
# a real apply boots an embedded Postgres on Pro (macOS named-volume
# caveat). So — following the modules/rds/cluster two-tier layout — the
# DEFAULT tests-localstack suite is plan-only: it confirms the module
# plans against the LocalStack provider endpoints with the VPC remote
# state stubbed via override_data, WITHOUT applying the RDS resource. It
# therefore passes on LocalStack Community — and even with no LocalStack
# at all, since a plan with overridden data makes no API calls.
#
# The full apply lives in ../tests-localstack-pro/apply_pro.tftest.hcl,
# gated behind `just tf test-localstack-pro rds/instance` (off by default).
#
# The `just tf test-localstack rds/instance` recipe wires
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
  region                    = "us-east-1"
  remote_state_bucket       = "tftest-rds-instance-state"
  vpc_name                  = "tftest-rds-instance-vpc"
  identifier_prefix         = "tftest-rds"
  engine                    = "postgres"
  instance_class            = "db.t3.micro"
  allocated_storage         = 20
  final_snapshot_identifier = "tftest-rds-final"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
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

run "plan_smoke" {
  command = plan

  assert {
    condition     = aws_db_instance.this.engine == "postgres"
    error_message = "instance must plan engine = postgres against the LocalStack provider"
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "instance must plan storage_encrypted = true"
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.t3.micro"
    error_message = "instance must plan the concrete var.instance_class"
  }

  assert {
    condition     = aws_db_instance.this.storage_type == "gp3"
    error_message = "instance must plan storage_type = gp3 by default"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "postgres18"
    error_message = "parameter family must resolve to postgres18 (default major)"
  }
}

run "plan_mysql" {
  command = plan

  variables {
    engine = "mysql"
  }

  assert {
    condition     = aws_db_instance.this.engine == "mysql"
    error_message = "plan must resolve mysql engine against LocalStack endpoints"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "mysql8.4"
    error_message = "MySQL parameter family must resolve to mysql8.4"
  }
}
