# Mode A plan-time invariants per IMPL-0004 Phase 7 / DESIGN-0004.
#
# Three managed policies + one customer-managed + two inline policies
# expand to one IAM role + four attachments + two inline policies + one
# Pod Identity Association.

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
  namespace           = "kube-system"
  service_account     = "cluster-autoscaler"
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AutoScalingFullAccess",
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess",
  ]
  customer_managed_policy_arns = [
    "arn:aws:iam::123456789012:policy/CustomClusterAutoscaler",
  ]
  inline_policies = {
    deny-elbv2 = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"elasticloadbalancing:*\",\"Resource\":\"*\"}]}"
    deny-s3    = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"s3:*\",\"Resource\":\"*\"}]}"
  }
  tags = {
    Environment = "test"
  }
  association_tags = {
    Component = "cluster-autoscaler"
  }
}

run "plan_mode_a" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  # Exactly one IAM role created (Mode A).
  assert {
    condition     = length(aws_iam_role.this) == 1
    error_message = "Mode A must create exactly one IAM role"
  }
  assert {
    condition     = aws_iam_role.this[0].name == "libtftest-cluster-kube-system-cluster-autoscaler"
    error_message = "Mode A role name must default to <cluster_name>-<namespace>-<service_account>"
  }

  # Trust policy shape.
  assert {
    condition     = strcontains(data.aws_iam_policy_document.pod_identity_trust[0].json, "pods.eks.amazonaws.com")
    error_message = "Trust policy must list pods.eks.amazonaws.com as principal"
  }
  assert {
    condition     = strcontains(data.aws_iam_policy_document.pod_identity_trust[0].json, "sts:AssumeRole") && strcontains(data.aws_iam_policy_document.pod_identity_trust[0].json, "sts:TagSession")
    error_message = "Trust policy must permit sts:AssumeRole and sts:TagSession"
  }

  # Attachment counts.
  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 3
    error_message = "Three managed policy ARNs must produce three attachments"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.customer) == 1
    error_message = "One customer-managed policy ARN must produce one attachment"
  }
  assert {
    condition     = length(aws_iam_role_policy.inline) == 2
    error_message = "Two inline policies must produce two aws_iam_role_policy resources"
  }

  # The Pod Identity Association — module's reason to exist.
  assert {
    condition     = aws_eks_pod_identity_association.this.cluster_name == "libtftest-cluster"
    error_message = "Association must bind to the remote-state cluster_name"
  }
  assert {
    condition     = aws_eks_pod_identity_association.this.namespace == "kube-system" && aws_eks_pod_identity_association.this.service_account == "cluster-autoscaler"
    error_message = "Association namespace + service_account must match inputs"
  }
}
