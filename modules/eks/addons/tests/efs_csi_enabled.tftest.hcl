# EFS CSI opt-in. var.efs_csi_enabled = true adds the addon, its IAM role,
# its policy attachment, and its addon-managed PIA block.

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
  efs_csi_enabled            = true
  tags = {
    Account     = "000000000000"
    ClusterName = "libtftest-cluster"
    ClusterType = "secure"
    Environment = "test"
    Region      = "us-east-1"
  }
}

run "efs_csi_enabled" {
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

  override_data {
    target = data.aws_eks_addon_version.efs_csi[0]
    values = {
      version = "v2.0.0-eksbuild.1"
    }
  }

  assert {
    condition     = length(aws_iam_role.efs_csi) == 1
    error_message = "EFS CSI IAM role must exist when var.efs_csi_enabled = true"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.efs_csi) == 1 && aws_iam_role_policy_attachment.efs_csi[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
    error_message = "EFS CSI role must attach exactly AmazonEFSCSIDriverPolicy"
  }
  assert {
    condition     = length(aws_eks_addon.efs_csi_driver) == 1 && aws_eks_addon.efs_csi_driver[0].addon_name == "aws-efs-csi-driver"
    error_message = "EFS CSI addon must register as aws-efs-csi-driver"
  }
  assert {
    condition     = length(aws_eks_addon.efs_csi_driver[0].pod_identity_association) == 1 && one(aws_eks_addon.efs_csi_driver[0].pod_identity_association).service_account == "efs-csi-controller-sa"
    error_message = "EFS CSI addon must carry exactly one PIA block bound to efs-csi-controller-sa"
  }
}
