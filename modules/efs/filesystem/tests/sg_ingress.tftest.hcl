# Security group ingress topology.
#
# from_nodes is always present (resolved from EKS remote state).
# from_extra iterates over var.additional_allowed_consumer_sg_ids:
# two-entry list creates two extra rules; empty list creates zero.

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

run "two_extra_consumers" {
  command = plan

  variables {
    additional_allowed_consumer_sg_ids = ["sg-aaa1234567", "sg-bbb7654321"]
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

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        node_security_group_id = "sg-node1234567890"
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.from_extra) == 2
    error_message = "Two additional consumer SGs must produce exactly two from_extra ingress rules"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_extra["sg-aaa1234567"].from_port == 2049
    error_message = "from_extra ingress rule must use NFS port 2049"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_extra["sg-aaa1234567"].ip_protocol == "tcp"
    error_message = "from_extra ingress rule must be TCP"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_nodes.referenced_security_group_id == "sg-node1234567890"
    error_message = "from_nodes ingress rule must still reference the node SG when extras are added"
  }
}

run "empty_extras" {
  command = plan

  variables {
    additional_allowed_consumer_sg_ids = []
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

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        node_security_group_id = "sg-node1234567890"
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.from_extra) == 0
    error_message = "Empty additional_allowed_consumer_sg_ids must produce zero from_extra ingress rules"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_nodes.from_port == 2049
    error_message = "from_nodes ingress rule must remain present when extras are empty"
  }
}
