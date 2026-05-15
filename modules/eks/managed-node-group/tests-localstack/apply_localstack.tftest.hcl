# Apply against LocalStack — the gap-discovery mode per RFC-0001.
#
# This file exercises `command = apply` against LocalStack Pro to
# surface what LocalStack actually serves for the managed-node-group's
# AWS API surface: IAM role + instance profile, EC2 launch template
# (incl. KMS-encrypted EBS), EKS node group registration.
#
# Required env vars (the harness wiring terraform test needs to reach
# LocalStack — same shape libtftest's helpers_test.go wires in Go):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# The `just tf test-localstack` recipe wires these for you.
#
# Findings are captured in FINDINGS.md as the LocalStack apply hits
# rough edges. Any 501 / NotImplemented becomes a sneakystack ticket
# per RFC-0001 §`terraform test` as the gap-discovery tool.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    cloudwatchlogs = "http://localhost:4566"
    ec2            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    kms            = "http://localhost:4566"
    s3             = "http://s3.localhost.localstack.cloud:4566"
    sts            = "http://localhost:4566"
  }
}

variables {
  remote_state_bucket = "tftest-mng-bucket"
  region              = "us-east-1"
  cluster_name        = "tftest-mng-cluster"
  vpc_name            = "tftest-mng-vpc"
  nodegroup_name      = "tftest-mng"
  tags = {
    Environment = "test"
    ClusterName = "tftest-mng-cluster"
  }
}

# Setup: VPC + subnets + KMS + cluster IAM + real aws_eks_cluster +
# node SG + S3 bucket holding stub VPC and EKS state files. The
# fixture's apply produces the prerequisites the node-group module's
# remote-state reads need.
run "setup" {
  command = apply

  variables {
    remote_state_bucket = var.remote_state_bucket
    vpc_name            = var.vpc_name
    cluster_name        = var.cluster_name
    region              = var.region
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

# Default-config apply against LocalStack. Exercises IAM role +
# instance profile + 2 managed-policy attachments, EC2 launch template
# with KMS-encrypted EBS root, and aws_eks_node_group registration.
run "default_apply" {
  command = apply

  assert {
    condition     = length(aws_iam_role.node.arn) > 0
    error_message = "LocalStack IAM must populate node role ARN"
  }
  assert {
    condition     = length(aws_iam_instance_profile.node.arn) > 0
    error_message = "LocalStack IAM must populate instance profile ARN"
  }
  assert {
    condition     = length(aws_launch_template.node.id) > 0
    error_message = "LocalStack EC2 must populate launch template ID"
  }
  assert {
    condition     = aws_launch_template.node.latest_version >= 1
    error_message = "LocalStack EC2 must populate launch template latest_version"
  }
  assert {
    condition     = length(aws_eks_node_group.this.arn) > 0
    error_message = "LocalStack EKS must populate node group ARN"
  }
  assert {
    condition     = aws_eks_node_group.this.ami_type == "AL2023_ARM_64_STANDARD"
    error_message = "LocalStack EKS must accept the AL2023_ARM_64_STANDARD ami_type"
  }
  assert {
    condition     = aws_eks_node_group.this.capacity_type == "ON_DEMAND"
    error_message = "LocalStack EKS must reflect ON_DEMAND capacity type"
  }
}
