# Default-config plan-time invariants per RFC-0001 / ADR-0013.
#
# Stubs (override_data):
#   - data.terraform_remote_state.eks — cluster module's contract,
#     including cluster_version (Q2 — consumed by every addon-version
#     data source).
#   - data.aws_eks_addon_version.<addon> — five mandatory addons; each
#     stub returns a known version literal so coalesce() falls through
#     to it (caller passes null for every *_version input except the
#     agent, where IMPL-0003 Phase 9 directs a literal pin).

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  remote_state_bucket        = "stub-bucket"
  region                     = "us-east-1"
  cluster_name               = "libtftest-cluster"
  pod_identity_agent_version = "v1.3.0-eksbuild.1"
  tags = {
    Account     = "000000000000"
    ClusterName = "libtftest-cluster"
    ClusterType = "secure"
    Environment = "test"
    Region      = "us-east-1"
  }
}

run "default_plan" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name    = "libtftest-cluster"
        cluster_version = "1.31"
      }
    }
  }

  override_data {
    target = data.aws_eks_addon_version.pod_identity_agent
    values = {
      version = "v1.3.0-eksbuild.1"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.vpc_cni
    values = {
      version = "v1.18.0-eksbuild.1"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.kube_proxy
    values = {
      version = "v1.31.0-eksbuild.2"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.coredns
    values = {
      version = "v1.11.3-eksbuild.1"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.ebs_csi
    values = {
      version = "v1.35.0-eksbuild.1"
    }
  }

  # Five addons (agent + four mandatory), zero EFS by default.
  assert {
    condition     = aws_eks_addon.pod_identity_agent.addon_name == "eks-pod-identity-agent"
    error_message = "Agent addon must register as eks-pod-identity-agent"
  }
  assert {
    condition     = aws_eks_addon.vpc_cni.addon_name == "vpc-cni"
    error_message = "VPC CNI addon must register as vpc-cni"
  }
  assert {
    condition     = aws_eks_addon.kube_proxy.addon_name == "kube-proxy"
    error_message = "kube-proxy addon must register as kube-proxy"
  }
  assert {
    condition     = aws_eks_addon.coredns.addon_name == "coredns"
    error_message = "CoreDNS addon must register as coredns"
  }
  assert {
    condition     = aws_eks_addon.ebs_csi_driver.addon_name == "aws-ebs-csi-driver"
    error_message = "EBS CSI addon must register as aws-ebs-csi-driver"
  }

  # PIA contract — most load-bearing assertion set per DESIGN-0003.
  assert {
    condition     = length(aws_eks_addon.pod_identity_agent.pod_identity_association) == 0
    error_message = "Agent addon must have zero pod_identity_association blocks (the agent IS the PIA delivery mechanism)"
  }
  assert {
    condition     = length(aws_eks_addon.vpc_cni.pod_identity_association) == 1 && one(aws_eks_addon.vpc_cni.pod_identity_association).service_account == "aws-node"
    error_message = "VPC CNI addon must carry exactly one PIA block bound to aws-node"
  }
  assert {
    condition     = length(aws_eks_addon.ebs_csi_driver.pod_identity_association) == 1 && one(aws_eks_addon.ebs_csi_driver.pod_identity_association).service_account == "ebs-csi-controller-sa"
    error_message = "EBS CSI addon must carry exactly one PIA block bound to ebs-csi-controller-sa"
  }
  assert {
    condition     = length(aws_eks_addon.kube_proxy.pod_identity_association) == 0 && length(aws_eks_addon.coredns.pod_identity_association) == 0
    error_message = "kube-proxy and CoreDNS addons must have zero pod_identity_association blocks"
  }

  # IAM role + single managed policy attachment per addon-managed-PIA addon.
  assert {
    condition     = aws_iam_role_policy_attachment.vpc_cni.policy_arn == "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    error_message = "VPC CNI role must attach exactly AmazonEKS_CNI_Policy"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    error_message = "EBS CSI role must attach exactly AmazonEBSCSIDriverPolicy"
  }

  # Shared trust policy — pods.eks.amazonaws.com with both AssumeRole and TagSession.
  assert {
    condition     = strcontains(data.aws_iam_policy_document.pod_identity_trust.json, "pods.eks.amazonaws.com")
    error_message = "Shared trust policy must list pods.eks.amazonaws.com as principal"
  }
  assert {
    condition     = strcontains(data.aws_iam_policy_document.pod_identity_trust.json, "sts:AssumeRole") && strcontains(data.aws_iam_policy_document.pod_identity_trust.json, "sts:TagSession")
    error_message = "Shared trust policy must permit sts:AssumeRole and sts:TagSession"
  }

  # Conflict resolution per DESIGN-0003.
  assert {
    condition     = aws_eks_addon.pod_identity_agent.resolve_conflicts_on_create == "OVERWRITE" && aws_eks_addon.pod_identity_agent.resolve_conflicts_on_update == "PRESERVE"
    error_message = "Agent addon must use OVERWRITE on create and PRESERVE on update"
  }

  # EFS off by default — count-gated resources should be empty.
  assert {
    condition     = length(aws_iam_role.efs_csi) == 0 && length(aws_eks_addon.efs_csi_driver) == 0
    error_message = "EFS CSI resources must be empty when var.efs_csi_enabled = false"
  }
}
