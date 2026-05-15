# Architecture-input validation per IMPL-0002 Phase 7.
#
# Covers: variable validation negatives, amd64 happy path, and the
# resource-precondition cross-arch instance-type guard.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  remote_state_bucket = "stub-bucket"
  region              = "us-east-1"
  cluster_name        = "libtftest-cluster"
  vpc_name            = "libtftest-vpc"
  nodegroup_name      = "libtftest-ng"
}

run "x86_rejected" {
  command = plan

  variables {
    architecture = {
      name                   = "x86"
      ami_type               = "AL2023_x86_64_STANDARD"
      gvisor_arch            = "x86_64"
      k8s_arch               = "amd64"
      default_instance_types = ["m7i.large"]
    }
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name              = "libtftest-cluster"
        cluster_version           = "1.31"
        cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
        cluster_ca_data           = "Y2EtZGF0YQ=="
        cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
        cluster_security_group_id = "sg-cluster-stub"
        node_security_group_id    = "sg-node-stub"
        kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-a", "subnet-b"]
        public_subnet_ids  = ["subnet-pub-a", "subnet-pub-b"]
      }
    }
  }

  expect_failures = [var.architecture]
}

run "amd64_accepted" {
  command = plan

  variables {
    architecture = {
      name                   = "amd64"
      ami_type               = "AL2023_x86_64_STANDARD"
      gvisor_arch            = "x86_64"
      k8s_arch               = "amd64"
      default_instance_types = ["m7i.large", "c7i.large"]
    }
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name              = "libtftest-cluster"
        cluster_version           = "1.31"
        cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
        cluster_ca_data           = "Y2EtZGF0YQ=="
        cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
        cluster_security_group_id = "sg-cluster-stub"
        node_security_group_id    = "sg-node-stub"
        kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-a", "subnet-b"]
        public_subnet_ids  = ["subnet-pub-a", "subnet-pub-b"]
      }
    }
  }

  assert {
    condition     = aws_eks_node_group.this.ami_type == "AL2023_x86_64_STANDARD"
    error_message = "amd64 architecture must select AL2023_x86_64_STANDARD ami_type"
  }
  assert {
    condition     = aws_eks_node_group.this.labels["kubernetes.io/arch"] == "amd64"
    error_message = "amd64 architecture must set kubernetes.io/arch=amd64 label"
  }
}

run "capacity_type_invalid" {
  command = plan

  variables {
    capacity_type = "FOO"
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name              = "libtftest-cluster"
        cluster_version           = "1.31"
        cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
        cluster_ca_data           = "Y2EtZGF0YQ=="
        cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
        cluster_security_group_id = "sg-cluster-stub"
        node_security_group_id    = "sg-node-stub"
        kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-a", "subnet-b"]
        public_subnet_ids  = ["subnet-pub-a", "subnet-pub-b"]
      }
    }
  }

  expect_failures = [var.capacity_type]
}

run "cross_arch_instance_type_rejected" {
  command = plan

  variables {
    # Default architecture is arm64; force amd64 instance type.
    instance_types = ["m7i.large"]
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name              = "libtftest-cluster"
        cluster_version           = "1.31"
        cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
        cluster_ca_data           = "Y2EtZGF0YQ=="
        cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
        cluster_security_group_id = "sg-cluster-stub"
        node_security_group_id    = "sg-node-stub"
        kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-a", "subnet-b"]
        public_subnet_ids  = ["subnet-pub-a", "subnet-pub-b"]
      }
    }
  }

  expect_failures = [aws_eks_node_group.this]
}
