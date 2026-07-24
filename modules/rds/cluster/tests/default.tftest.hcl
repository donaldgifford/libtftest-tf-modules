# Default-shape plan-time invariants per IMPL-0012 Phase 9.
#
# One run per engine (aurora-postgresql + aurora-mysql). Each run uses
# BYO KMS so local.kms_key_arn is plan-known where asserted (lesson from
# IMPL-0006 — a module-managed KMS ARN is unknown at plan). A dedicated
# "managed_kms_count" run separately verifies the count-gated
# module-managed KMS key + alias are created when var.kms_key_arn is null.
#
# The provisioned-cluster distinction vs serverless is asserted directly:
# NO serverlessv2_scaling_configuration block, and instance_class is a
# real class (var.instance_class), never the db.serverless sentinel.

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
  instance_class            = "db.r6g.large"
  final_snapshot_identifier = "platform-rds-final-test"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "default_postgres" {
  command = plan

  variables {
    engine = "aurora-postgresql"
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
    condition     = aws_rds_cluster.this.engine == "aurora-postgresql"
    error_message = "Cluster engine must be aurora-postgresql"
  }

  assert {
    condition     = aws_rds_cluster.this.engine_mode == "provisioned"
    error_message = "engine_mode must be \"provisioned\""
  }

  assert {
    condition     = length(aws_rds_cluster.this.serverlessv2_scaling_configuration) == 0
    error_message = "A provisioned cluster must NOT set a serverlessv2_scaling_configuration block (that is the serverless module)"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.r6g.large"
    error_message = "Writer instance_class must equal var.instance_class (a real class), NOT db.serverless"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.identifier == "platform-rds-1"
    error_message = "Writer identifier must be <identifier_prefix>-1 (Q7 — reserves the -replica-<key> namespace)"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.promotion_tier == 0
    error_message = "Writer promotion_tier must default to 0 (highest-priority failover target)"
  }

  assert {
    condition     = aws_rds_cluster.this.storage_encrypted == true
    error_message = "storage_encrypted must default to true"
  }

  assert {
    condition     = aws_rds_cluster.this.deletion_protection == true
    error_message = "deletion_protection must default to true"
  }

  assert {
    condition     = aws_rds_cluster.this.manage_master_user_password == true
    error_message = "manage_master_user_password must default to true"
  }

  assert {
    condition     = aws_rds_cluster.this.master_username == "admin"
    error_message = "master_username must default to \"admin\" (per IMPL-0007 Q4)"
  }

  assert {
    condition     = aws_rds_cluster.this.kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "kms_key_id must equal the BYO ARN under BYO mode"
  }

  assert {
    condition     = aws_rds_cluster.this.master_user_secret_kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "master_user_secret_kms_key_id must equal local.kms_key_arn (per IMPL-0007 Q12 — same key for both encryptions)"
  }

  assert {
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-postgresql18"
    error_message = "Cluster parameter group family must resolve to aurora-postgresql18 (default major = 18)"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "aurora-postgresql18"
    error_message = "Instance parameter group family must resolve to aurora-postgresql18"
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_key resources"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_alias resources"
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
    engine = "aurora-mysql"
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
    condition     = aws_rds_cluster.this.engine == "aurora-mysql"
    error_message = "Cluster engine must be aurora-mysql"
  }

  assert {
    condition     = aws_rds_cluster.this.engine_mode == "provisioned"
    error_message = "engine_mode must be \"provisioned\" for MySQL too"
  }

  assert {
    condition     = length(aws_rds_cluster.this.serverlessv2_scaling_configuration) == 0
    error_message = "MySQL provisioned cluster must NOT set a serverlessv2_scaling_configuration block"
  }

  assert {
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-mysql8.0"
    error_message = "MySQL cluster parameter group family must resolve to aurora-mysql8.0 (default major.minor = 8.0)"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.r6g.large"
    error_message = "MySQL writer instance_class must equal var.instance_class, NOT db.serverless"
  }
}

run "managed_kms_count" {
  command = plan

  variables {
    engine      = "aurora-postgresql"
    kms_key_arn = null
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
    condition     = length(aws_kms_key.this) == 1
    error_message = "Module-managed mode must plan exactly one aws_kms_key resource"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 1
    error_message = "Module-managed mode must plan exactly one aws_kms_alias resource"
  }
}
