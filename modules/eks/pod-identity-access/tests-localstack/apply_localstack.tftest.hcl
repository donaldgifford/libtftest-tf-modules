# Apply against LocalStack — gap-discovery mode per RFC-0001 / IMPL-0004 Q3.
#
# Probes LocalStack Pro's coverage for aws_eks_pod_identity_association
# (relatively new EKS API surface) and the IAM role + attachment lifecycle.
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
# Findings captured in FINDINGS.md.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "http://localhost:4566"
    eks = "http://localhost:4566"
    iam = "http://localhost:4566"
    s3  = "http://s3.localhost.localstack.cloud:4566"
    sts = "http://localhost:4566"
  }
}

variables {
  remote_state_bucket = "tftest-pia-bucket"
  region              = "us-east-1"
  cluster_name        = "tftest-pia-cluster"
  namespace           = "kube-system"
  service_account     = "tftest-sa"
  tags = {
    Environment = "test"
  }
}

# Setup: VPC + cluster + a pre-existing PIA-trusting role + S3 stub state.
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

# Mode A: module creates the role + one managed attachment + one inline
# policy + the association.
run "apply_mode_a" {
  command = apply

  variables {
    service_account = "tftest-sa-mode-a"
    managed_policy_arns = [
      "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    ]
    inline_policies = {
      deny-all-s3 = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"s3:*\",\"Resource\":\"*\"}]}"
    }
  }

  assert {
    condition     = length(aws_iam_role.this[0].arn) > 0
    error_message = "LocalStack IAM must populate the Mode A role ARN"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 1
    error_message = "Mode A apply must produce exactly one managed-policy attachment"
  }
  assert {
    condition     = length(aws_iam_role_policy.inline) == 1
    error_message = "Mode A apply must produce exactly one inline policy"
  }
  assert {
    condition     = length(aws_eks_pod_identity_association.this.association_id) > 0
    error_message = "LocalStack EKS must populate the Pod Identity Association ID"
  }
  assert {
    condition     = aws_eks_pod_identity_association.this.role_arn == aws_iam_role.this[0].arn
    error_message = "Mode A association's role_arn must equal the created role's ARN"
  }
}

# Mode B: caller passes the pre-existing role ARN from the setup fixture;
# module creates ONLY the association.
run "apply_mode_b" {
  command = apply

  variables {
    create_role       = false
    existing_role_arn = run.setup.preexisting_role_arn
    service_account   = "tftest-sa-mode-b"
  }

  assert {
    condition     = length(aws_iam_role.this) == 0
    error_message = "Mode B must create zero IAM roles on apply"
  }
  assert {
    condition     = length(aws_eks_pod_identity_association.this.association_id) > 0
    error_message = "LocalStack EKS must populate the association ID for Mode B too"
  }
  assert {
    condition     = aws_eks_pod_identity_association.this.role_arn == run.setup.preexisting_role_arn
    error_message = "Mode B association's role_arn must echo the pre-existing role ARN from the setup fixture"
  }
}
