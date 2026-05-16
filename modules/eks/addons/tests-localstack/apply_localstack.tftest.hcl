# Apply against LocalStack — gap-discovery mode per RFC-0001.
#
# Probes LocalStack Pro's EKS addon API surface for this module:
#   - aws_eks_addon registration for all six addons.
#   - addon-managed pod_identity_association block on VPC CNI /
#     EBS CSI / EFS CSI.
#   - data.aws_eks_addon_version catalog response.
#   - IAM role + managed-policy attachments.
#
# Required env vars (the harness wiring terraform test needs to reach
# LocalStack):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# The `just tf test-localstack` recipe wires these for you.
#
# Findings are captured in FINDINGS.md.

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
  remote_state_bucket = "tftest-addons-bucket"
  region              = "us-east-1"
  cluster_name        = "tftest-addons-cluster"
  # Versions pinned to what LocalStack Pro publishes for K8s 1.35 in
  # describe-addon-versions. Caller-pinned versions short-circuit the
  # data source (IMPL-0003 Q4 — keep the apply test deterministic
  # regardless of what LocalStack's catalog returns on a given day).
  pod_identity_agent_version = "v1.3.10-eksbuild.2"
  vpc_cni_version            = "v1.21.1-eksbuild.7"
  kube_proxy_version         = "v1.35.3-eksbuild.2"
  coredns_version            = "v1.13.2-eksbuild.4"
  ebs_csi_version            = "v1.57.1-eksbuild.1"
  tags = {
    Account     = "000000000000"
    ClusterName = "tftest-addons-cluster"
    ClusterType = "secure"
    Environment = "test"
    Region      = "us-east-1"
  }
}

# Setup: VPC + subnets + KMS + cluster IAM + real aws_eks_cluster + S3
# bucket with stub EKS state. Produces what the addons module's
# data.terraform_remote_state.eks needs.
run "setup" {
  command = apply

  variables {
    remote_state_bucket = var.remote_state_bucket
    cluster_name        = var.cluster_name
    region              = var.region
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

# Default-config apply against LocalStack. Every addon-version variable
# is pinned literally to bypass data.aws_eks_addon_version, which queries
# AWS's published addon catalog — LocalStack's coverage of that endpoint
# is the first thing this run surfaces.
run "default_apply" {
  command = apply

  assert {
    condition     = length(aws_eks_addon.pod_identity_agent.arn) > 0
    error_message = "LocalStack EKS must populate the agent addon ARN"
  }
  assert {
    condition     = aws_eks_addon.pod_identity_agent.addon_name == "eks-pod-identity-agent"
    error_message = "Agent addon registered against the wrong addon_name"
  }
  assert {
    condition     = length(aws_eks_addon.vpc_cni.arn) > 0
    error_message = "LocalStack EKS must populate the VPC CNI addon ARN"
  }
  assert {
    condition     = length(aws_eks_addon.kube_proxy.arn) > 0
    error_message = "LocalStack EKS must populate the kube-proxy addon ARN"
  }
  assert {
    condition     = length(aws_eks_addon.coredns.arn) > 0
    error_message = "LocalStack EKS must populate the CoreDNS addon ARN"
  }
  assert {
    condition     = length(aws_eks_addon.ebs_csi_driver.arn) > 0
    error_message = "LocalStack EKS must populate the EBS CSI addon ARN"
  }
  assert {
    condition     = length(aws_iam_role.vpc_cni.arn) > 0
    error_message = "LocalStack IAM must populate the VPC CNI Pod Identity role ARN"
  }
  assert {
    condition     = length(aws_iam_role.ebs_csi.arn) > 0
    error_message = "LocalStack IAM must populate the EBS CSI Pod Identity role ARN"
  }
  assert {
    condition     = length(aws_eks_addon.vpc_cni.pod_identity_association) == 1 && one(aws_eks_addon.vpc_cni.pod_identity_association).service_account == "aws-node"
    error_message = "LocalStack EKS must register VPC CNI's pod_identity_association block (aws-node)"
  }
  assert {
    condition     = length(aws_eks_addon.ebs_csi_driver.pod_identity_association) == 1 && one(aws_eks_addon.ebs_csi_driver.pod_identity_association).service_account == "ebs-csi-controller-sa"
    error_message = "LocalStack EKS must register EBS CSI's pod_identity_association block (ebs-csi-controller-sa)"
  }
}
