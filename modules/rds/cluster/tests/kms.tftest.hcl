# KMS resolution — the count-gated module-managed key vs BYO ARN.
#
# var.kms_key_arn null  → module creates exactly one aws_kms_key + alias,
#                         and local.kms_key_arn threads that key through.
# var.kms_key_arn set   → zero module-managed key/alias, and the BYO ARN
#                         echoes into the cluster's storage-encryption +
#                         master-user-secret-encryption attributes.

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
  engine                    = "aurora-postgresql"
  instance_class            = "db.r6g.large"
  final_snapshot_identifier = "platform-rds-final-test"
}

run "managed_kms" {
  command = plan

  variables {
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

  assert {
    condition     = aws_kms_alias.this[0].name == "alias/platform-rds-rds-cluster"
    error_message = "Module-managed KMS alias name must be alias/<identifier_prefix>-rds-cluster"
  }

  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation == true
    error_message = "Module-managed KMS key must enable annual rotation"
  }
}

run "byo_kms" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
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
    condition     = length(aws_kms_key.this) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_key resources"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_alias resources"
  }

  assert {
    condition     = aws_rds_cluster.this.kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "kms_key_id must equal the BYO ARN"
  }

  assert {
    condition     = aws_rds_cluster.this.master_user_secret_kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "master_user_secret_kms_key_id must equal the BYO ARN (per IMPL-0007 Q12)"
  }
}
