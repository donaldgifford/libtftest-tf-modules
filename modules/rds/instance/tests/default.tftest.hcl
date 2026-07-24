# Default-shape plan-time invariants (IMPL-0011 Phase 8).
#
# One run per engine (Q6): postgres + mysql. Each run uses BYO KMS so
# local.kms_key_arn is plan-known where asserted (lesson from IMPL-0006 —
# a module-managed KMS ARN is unknown at plan). The managed-KMS count is
# verified separately in kms.tftest.hcl.

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

run "default_postgres" {
  command = plan

  variables {
    engine = "postgres"
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
    condition     = aws_db_instance.this.engine == "postgres"
    error_message = "Instance engine must be postgres"
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "storage_encrypted must default to true"
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == true
    error_message = "deletion_protection must default to true"
  }

  assert {
    condition     = aws_db_instance.this.multi_az == false
    error_message = "multi_az must default to false (single-AZ; operators opt into HA, DESIGN-0012 Q4)"
  }

  assert {
    condition     = aws_db_instance.this.storage_type == "gp3"
    error_message = "storage_type must default to gp3"
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true
    error_message = "manage_master_user_password must default to true"
  }

  assert {
    condition     = aws_db_instance.this.username == "admin"
    error_message = "username must default to \"admin\" (per IMPL-0007 Q4)"
  }

  assert {
    condition     = aws_db_instance.this.kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "kms_key_id must equal the BYO ARN under BYO mode"
  }

  assert {
    condition     = aws_db_instance.this.master_user_secret_kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "master_user_secret_kms_key_id must equal local.kms_key_arn (per IMPL-0007 Q12 — same key for both encryptions)"
  }

  assert {
    condition     = aws_db_instance.this.port == 5432
    error_message = "Postgres instance must listen on 5432"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "postgres18"
    error_message = "Instance parameter group family must resolve to postgres18 (default major = 18)"
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_key resources"
  }

  # RDS Proxy composition outputs (DESIGN-0010 Q11-a / IMPL-0010 Phase 2).
  # master_user_secret_kms_key_arn reads the computed master_user_secret
  # block (known only after apply), so it is not plan-asserted here — its
  # source argument is covered by the master_user_secret_kms_key_id assert
  # above.
  assert {
    condition     = output.vpc_id == "vpc-0123456789abcdef0"
    error_message = "vpc_id output must surface the VPC from remote state for RDS Proxy SG placement"
  }

  assert {
    condition     = length(output.db_subnet_ids) == 3
    error_message = "db_subnet_ids output must surface all three private subnets for RDS Proxy vpc_subnet_ids"
  }

  assert {
    condition     = contains(output.db_subnet_ids, "subnet-aaa")
    error_message = "db_subnet_ids output must contain the subnet IDs read from VPC remote state"
  }

  assert {
    condition     = output.iam_database_authentication_enabled == false
    error_message = "iam_database_authentication_enabled output must default to false (proxy V4 precondition reads this)"
  }
}

run "default_mysql" {
  command = plan

  variables {
    engine = "mysql"
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
    condition     = aws_db_instance.this.engine == "mysql"
    error_message = "Instance engine must be mysql"
  }

  assert {
    condition     = aws_db_instance.this.port == 3306
    error_message = "MySQL instance must listen on 3306"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "mysql8.4"
    error_message = "MySQL instance parameter group family must resolve to mysql8.4 (default major.minor = 8.4)"
  }
}
