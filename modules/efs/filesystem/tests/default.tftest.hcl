# Default-shape plan-time invariants per IMPL-0008 Phase 9.
#
# Uses BYO KMS so local.kms_key_arn is plan-known (the module-managed
# key's ARN is apply-time-only — same lesson as IMPL-0006 / IMPL-0007).
# Both remote-state data sources are stubbed via override_data so
# terraform test does not try a real S3 read before variable validation
# fires (the IMPL-0007 Phase 9 lesson).

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

run "default_shape" {
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
    condition     = aws_efs_file_system.this.encrypted == true
    error_message = "encrypted must default to true"
  }

  assert {
    condition     = aws_efs_file_system.this.kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "kms_key_id must equal the BYO ARN under BYO mode"
  }

  assert {
    condition     = aws_efs_file_system.this.performance_mode == "generalPurpose"
    error_message = "performance_mode must default to generalPurpose (DESIGN-0008 Q2)"
  }

  assert {
    condition     = aws_efs_file_system.this.throughput_mode == "elastic"
    error_message = "throughput_mode must default to elastic (DESIGN-0008 Q3)"
  }

  assert {
    condition     = aws_efs_file_system.this.creation_token == "platform-efs"
    error_message = "creation_token must equal var.identifier_prefix (DESIGN-0008 Q10)"
  }

  assert {
    condition     = length(aws_efs_mount_target.this) == 3
    error_message = "Three private subnets must produce exactly three mount targets"
  }

  assert {
    condition     = aws_security_group.this.vpc_id == "vpc-0123456789abcdef0"
    error_message = "Security group must live in the VPC pulled from VPC remote state"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_nodes.referenced_security_group_id == "sg-node1234567890"
    error_message = "from_nodes ingress must reference the node SG pulled from EKS remote state"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_nodes.from_port == 2049
    error_message = "NFS ingress must use port 2049"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_nodes.ip_protocol == "tcp"
    error_message = "NFS ingress must be TCP"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.from_extra) == 0
    error_message = "additional_allowed_consumer_sg_ids defaults to [] — zero extra ingress rules"
  }

  assert {
    condition     = length(aws_efs_access_point.this) == 0
    error_message = "access_points defaults to {} — zero access points"
  }

  assert {
    condition     = length(aws_efs_backup_policy.this) == 0
    error_message = "backup_policy_enabled defaults to false — zero backup policies"
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_key resources"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 0
    error_message = "BYO KMS must plan zero module-managed aws_kms_alias resources"
  }
}
