# Fail-closed guards — IMPL-0020 Phase 4 (DESIGN-0024 part 1).
#
# Everything here is a misconfiguration that either AWS rejects at
# apply with a vaguer message, or (worse) accepts while granting more
# than the operator intended. Access is the highest-stakes surface in
# the fleet, so every one of them fails at plan.

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
}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_name      = "libtftest-cluster"
      sso_principal_arn = "arn:aws:iam::000000000000:role/AWSReservedSSO_Admin_abcdef1234567890"
    }
  }
}

run "rejects_wildcard_principal" {
  command = plan

  variables {
    access_entries = {
      too_broad = {
        principal_arn = "arn:aws:iam::000000000000:role/*"
      }
    }
  }

  expect_failures = [var.access_entries]
}

run "rejects_malformed_principal_arn" {
  command = plan

  variables {
    access_entries = {
      typo = {
        principal_arn = "arn:aws:iam::000000000000:group/platform"
      }
    }
  }

  expect_failures = [var.access_entries]
}

run "rejects_groups_on_non_standard_type" {
  command = plan

  variables {
    access_entries = {
      linux_nodes = {
        principal_arn     = "arn:aws:iam::000000000000:role/node-role"
        type              = "EC2_LINUX"
        kubernetes_groups = ["deploy"]
      }
    }
  }

  expect_failures = [var.access_entries]
}

run "rejects_unknown_entry_type" {
  command = plan

  variables {
    access_entries = {
      bogus = {
        principal_arn = "arn:aws:iam::000000000000:role/some-role"
        type          = "EC2_MACOS"
      }
    }
  }

  expect_failures = [var.access_entries]
}

# An IAM policy ARN pasted where a cluster-access-policy ARN belongs is
# the easy mistake — both start "arn:aws:" and only one works.
run "rejects_iam_policy_arn_as_access_policy" {
  command = plan

  variables {
    access_entries = {
      admin = {
        principal_arn = "arn:aws:iam::000000000000:role/some-role"
        policy_associations = {
          wrong = {
            policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
          }
        }
      }
    }
  }

  expect_failures = [var.access_entries]
}

run "rejects_namespace_scope_without_namespaces" {
  command = plan

  variables {
    access_entries = {
      scoped = {
        principal_arn = "arn:aws:iam::000000000000:role/some-role"
        policy_associations = {
          edit = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = { type = "namespace" }
          }
        }
      }
    }
  }

  expect_failures = [var.access_entries]
}

#--------------------------------------------------------------
# The cross-stack collision guard (task 4.5)
#--------------------------------------------------------------

# eks/cluster owns the SSO principal's entry. Declaring it here too is
# two stacks owning one AWS resource — AWS would only say so at apply.
run "rejects_principal_owned_by_the_cluster_stack" {
  command = plan

  variables {
    access_entries = {
      sso_admin = {
        principal_arn = "arn:aws:iam::000000000000:role/AWSReservedSSO_Admin_abcdef1234567890"
      }
    }
  }

  expect_failures = [aws_eks_access_entry.this]
}

# The same principal is fine when the cluster stack is NOT the owner —
# proving the guard compares ARNs rather than pattern-matching SSO.
run "allows_other_principals_alongside_the_sso_entry" {
  command = plan

  variables {
    access_entries = {
      deploy_role = {
        principal_arn = "arn:aws:iam::000000000000:role/deploy-role"
      }
    }
  }

  assert {
    condition     = aws_eks_access_entry.this["deploy_role"].principal_arn == "arn:aws:iam::000000000000:role/deploy-role"
    error_message = "a non-colliding principal must plan cleanly while the cluster's SSO entry exists"
  }
}
