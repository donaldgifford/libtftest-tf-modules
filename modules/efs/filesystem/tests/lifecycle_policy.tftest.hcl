# Lifecycle policy block dynamics.
#
# Default → IA + Archive blocks present; primary-storage block absent.
# var.lifecycle_policy = null → zero lifecycle_policy blocks.
# Partial override → optional() defaults fill the rest.

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

run "default_transitions" {
  command = plan

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
    condition     = length(aws_efs_file_system.this.lifecycle_policy) == 2
    error_message = "Default lifecycle_policy must emit exactly two blocks (IA + Archive); primary-storage default is null"
  }

  assert {
    condition     = aws_efs_file_system.this.lifecycle_policy[0].transition_to_ia == "AFTER_30_DAYS"
    error_message = "Default transition_to_ia must equal AFTER_30_DAYS"
  }

  assert {
    condition     = aws_efs_file_system.this.lifecycle_policy[1].transition_to_archive == "AFTER_90_DAYS"
    error_message = "Default transition_to_archive must equal AFTER_90_DAYS"
  }
}

run "null_disables_all" {
  command = plan

  variables {
    lifecycle_policy = null
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
    condition     = length(aws_efs_file_system.this.lifecycle_policy) == 0
    error_message = "var.lifecycle_policy = null must emit zero lifecycle_policy blocks"
  }
}

run "override_ia_only" {
  command = plan

  variables {
    lifecycle_policy = {
      transition_to_ia = "AFTER_60_DAYS"
    }
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
    condition     = aws_efs_file_system.this.lifecycle_policy[0].transition_to_ia == "AFTER_60_DAYS"
    error_message = "Override transition_to_ia must equal AFTER_60_DAYS"
  }

  assert {
    condition     = aws_efs_file_system.this.lifecycle_policy[1].transition_to_archive == "AFTER_90_DAYS"
    error_message = "Archive transition must fall back to the optional() default AFTER_90_DAYS"
  }
}

run "all_three_transitions" {
  command = plan

  variables {
    lifecycle_policy = {
      transition_to_ia                    = "AFTER_7_DAYS"
      transition_to_archive               = "AFTER_60_DAYS"
      transition_to_primary_storage_class = "AFTER_1_ACCESS"
    }
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
    condition     = length(aws_efs_file_system.this.lifecycle_policy) == 3
    error_message = "Three non-null transitions must emit three lifecycle_policy blocks"
  }

  assert {
    condition     = aws_efs_file_system.this.lifecycle_policy[2].transition_to_primary_storage_class == "AFTER_1_ACCESS"
    error_message = "transition_to_primary_storage_class block must emit when non-null"
  }
}
