# Default-config plan-time invariants per RFC-0001 / ADR-0013.
#
# Stubs (override_data):
#   - data.terraform_remote_state.eks — cluster module's contract,
#     including cluster_version (added 2026-05-15 per IMPL-0003 Q2).
#   - data.terraform_remote_state.vpc — VPC stack outputs.

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
  tags = {
    Account     = "libtftest"
    ClusterName = "libtftest-cluster"
    Environment = "test"
  }
}

run "default_plan" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name              = "libtftest-cluster"
        cluster_version           = "1.31"
        cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
        cluster_ca_data           = "Y2EtZGF0YQ==" # base64("ca-data")
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
        private_subnet_ids = ["subnet-private-a", "subnet-private-b"]
        public_subnet_ids  = ["subnet-public-a", "subnet-public-b"]
      }
    }
  }

  # IAM role name follows the ${nodegroup_name}-node convention.
  assert {
    condition     = aws_iam_role.node.name == "libtftest-ng-node"
    error_message = "node IAM role name must be ${var.nodegroup_name}-node"
  }

  # Exactly two managed-policy attachments by default (ADR-0002).
  # The SSM and extra_node_policies attachments are counted separately
  # in their own tests (ssm_enabled.tftest.hcl / extras.tftest.hcl).
  assert {
    condition     = aws_iam_role_policy_attachment.worker_node.policy_arn == "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    error_message = "AmazonEKSWorkerNodePolicy must be attached to the node role"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.ecr_pull_only.policy_arn == "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
    error_message = "AmazonEC2ContainerRegistryPullOnly must be attached to the node role"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.ssm) == 0
    error_message = "SSM attachment must not be created when var.enable_ssm is false"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.extra) == 0
    error_message = "extra_node_policies attachments must not be created when var.extra_node_policies is empty"
  }

  # IMDSv2 + hop=2 per ADR-0007.
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required (http_tokens=required) per ADR-0007"
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "IMDS hop limit must be 2 (Pod Identity Agent needs hop=2) per ADR-0007"
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].instance_metadata_tags == "enabled"
    error_message = "instance_metadata_tags must be enabled per ADR-0007"
  }

  # EBS root volume: gp3 + encrypted + KMS from stubbed remote state.
  assert {
    condition     = aws_launch_template.node.block_device_mappings[0].ebs[0].volume_type == "gp3"
    error_message = "root EBS volume must be gp3"
  }
  assert {
    condition     = aws_launch_template.node.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "root EBS volume must be encrypted (KMS-CMK per cluster module)"
  }
  assert {
    condition     = aws_launch_template.node.block_device_mappings[0].ebs[0].kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/stub-key"
    error_message = "root EBS KMS key must come from data.terraform_remote_state.eks.outputs.kms_key_arn"
  }

  # Always-on workload-class=secure:NO_SCHEDULE taint. taint is a typed
  # set (not list) per the AWS provider schema; iterate with for instead
  # of indexing — same RFC-0001 finding as the cluster module.
  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "secure" && t.effect == "NO_SCHEDULE"
    ]) == 1
    error_message = "always-on workload-class=secure:NO_SCHEDULE taint missing"
  }

  # ami_type matches architecture (default arm64).
  assert {
    condition     = aws_eks_node_group.this.ami_type == "AL2023_ARM_64_STANDARD"
    error_message = "ami_type must come from var.architecture.ami_type (default AL2023_ARM_64_STANDARD)"
  }

  # Node labels include the runtime + workload-class pair (ADR-0005).
  assert {
    condition     = aws_eks_node_group.this.labels["runtime"] == "gvisor"
    error_message = "runtime=gvisor label must be set"
  }
  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "secure"
    error_message = "workload-class=secure label must be set"
  }
  assert {
    condition     = aws_eks_node_group.this.labels["kubernetes.io/arch"] == "arm64"
    error_message = "kubernetes.io/arch label must come from var.architecture.k8s_arch"
  }

  # Cluster identity flows from remote state at the use site (ADR-0001).
  assert {
    condition     = aws_eks_node_group.this.cluster_name == "libtftest-cluster"
    error_message = "cluster_name must come from data.terraform_remote_state.eks.outputs.cluster_name"
  }
  assert {
    condition     = length(aws_eks_node_group.this.subnet_ids) == 2
    error_message = "subnet_ids must come from data.terraform_remote_state.vpc.outputs.private_subnet_ids (length 2)"
  }

  # ON_DEMAND default per ADR-0009.
  assert {
    condition     = aws_eks_node_group.this.capacity_type == "ON_DEMAND"
    error_message = "capacity_type default must be ON_DEMAND per ADR-0009"
  }
}
