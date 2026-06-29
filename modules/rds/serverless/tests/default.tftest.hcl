# Default-shape plan-time invariants per IMPL-0007 Phase 9.
#
# One run per engine (per Q13 resolution): aurora-postgresql + aurora-mysql.
# Each run uses BYO KMS so local.kms_key_arn is plan-known where asserted
# (lesson from IMPL-0006 — module-managed KMS ARN is unknown at plan).
# A dedicated "managed_kms_count" run separately verifies that the
# count-gated module-managed KMS key + alias are created when
# var.kms_key_arn is null.

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
  min_acu                   = 0.5
  max_acu                   = 4
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
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      }
    }
  }

  assert {
    condition     = aws_rds_cluster.this.engine == "aurora-postgresql"
    error_message = "Cluster engine must be aurora-postgresql"
  }

  assert {
    condition     = aws_rds_cluster.this.engine_mode == "provisioned"
    error_message = "engine_mode must be \"provisioned\" — engine_mode = \"serverless\" is the deprecated Aurora Serverless v1 path"
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
    condition     = length(aws_rds_cluster.this.serverlessv2_scaling_configuration) == 1
    error_message = "serverlessv2_scaling_configuration block must be set"
  }

  assert {
    condition     = aws_rds_cluster.this.serverlessv2_scaling_configuration[0].min_capacity == 0.5
    error_message = "min_capacity must equal var.min_acu"
  }

  assert {
    condition     = aws_rds_cluster.this.serverlessv2_scaling_configuration[0].max_capacity == 4
    error_message = "max_capacity must equal var.max_acu"
  }

  assert {
    condition     = aws_rds_cluster_instance.this.instance_class == "db.serverless"
    error_message = "instance_class must be \"db.serverless\" — the literal signal that the instance is Serverless v2"
  }

  assert {
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-postgresql16"
    error_message = "Cluster parameter group family must resolve to aurora-postgresql16 (default major = 16)"
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "aurora-postgresql16"
    error_message = "Instance parameter group family must resolve to aurora-postgresql16"
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
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      }
    }
  }

  assert {
    condition     = aws_rds_cluster.this.engine == "aurora-mysql"
    error_message = "Cluster engine must be aurora-mysql"
  }

  assert {
    condition     = aws_rds_cluster.this.engine_mode == "provisioned"
    error_message = "engine_mode must be \"provisioned\" for MySQL Serverless v2 too"
  }

  assert {
    condition     = aws_rds_cluster_parameter_group.this.family == "aurora-mysql8.0"
    error_message = "MySQL cluster parameter group family must resolve to aurora-mysql8.0 (default major.minor = 8.0)"
  }

  assert {
    condition     = aws_rds_cluster_instance.this.instance_class == "db.serverless"
    error_message = "MySQL instance must also be db.serverless"
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
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
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
