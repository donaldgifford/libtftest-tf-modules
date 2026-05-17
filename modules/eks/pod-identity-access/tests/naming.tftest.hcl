# Deterministic role name with 64-char truncation and override.
#
# Long-input run: joined default exceeds 64 chars → truncated to 57
# chars + "-" + 6-char sha256 prefix (totaling 64). Assert length is
# exactly 64 and the prefix matches the truncated joined fragment.
#
# Override run: role_name_override short-circuits the computed name.

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
  namespace           = "kube-system"
  service_account     = "test-sa"
}

run "long_inputs" {
  command = plan

  variables {
    # Joined default = "production-eks-cluster-very-long-namespace-name-very-long-service-account-name"
    # Length: 22 + 1 + 24 + 1 + 30 = 78 chars → triggers truncation.
    cluster_name    = "production-eks-cluster"
    namespace       = "very-long-namespace-name"
    service_account = "very-long-service-account-name"
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "production-eks-cluster"
      }
    }
  }

  # Truncated to exactly 64 chars (IAM hard limit).
  assert {
    condition     = length(aws_iam_role.this[0].name) == 64
    error_message = "Truncated role name must be exactly 64 chars (the IAM limit)"
  }

  # Prefix matches the first 57 chars of the joined default.
  assert {
    condition     = startswith(aws_iam_role.this[0].name, "production-eks-cluster-very-long-namespace-name-very-long")
    error_message = "Truncated role name must keep the first 57 chars of the joined default as its prefix"
  }

  # Hash suffix is hex (6 chars after the final "-").
  assert {
    condition     = can(regex("^production-eks-cluster-very-long-namespace-name-very-long-[0-9a-f]{6}$", aws_iam_role.this[0].name))
    error_message = "Truncated role name must end with a 6-hex-char sha256 prefix separated by a dash"
  }
}

run "override" {
  command = plan

  variables {
    cluster_name       = "anything"
    role_name_override = "my-custom-name"
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "anything"
      }
    }
  }

  assert {
    condition     = aws_iam_role.this[0].name == "my-custom-name"
    error_message = "role_name_override must short-circuit the computed name"
  }
}
