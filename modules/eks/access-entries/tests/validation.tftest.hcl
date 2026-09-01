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

# NOTE the deliberately PATH-BEARING sso_principal_arn: that is what
# data.aws_iam_roles actually returns for a reserved SSO role, and it
# is what the cluster module therefore publishes. The runs below name
# the same role in the conventional PATH-STRIPPED spelling used in
# access-entry configs — two strings, one principal — so the guard is
# exercised against the spelling mismatch that would otherwise let a
# duplicate entry through.
override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_name      = "libtftest-cluster"
      sso_principal_arn = "arn:aws:iam::000000000000:role/aws-reserved/sso.amazonaws.com/us-east-1/AWSReservedSSO_Admin_abcdef1234567890"
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

# access_scope.type defaults to "cluster", so writing only the
# namespaces half reads as a scoped grant but would silently discard
# the list and grant cluster-wide. The reviewer sees "team-a"; the API
# would see cluster-admin.
run "rejects_namespaces_without_explicit_namespace_scope" {
  command = plan

  variables {
    access_entries = {
      looks_scoped = {
        principal_arn = "arn:aws:iam::000000000000:role/some-role"
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { namespaces = ["team-a"] }
          }
        }
      }
    }
  }

  expect_failures = [var.access_entries]
}

# One principal, one entry: a principal's effective access is the union
# of its associations, so a duplicate can silently widen a tightly
# scoped entry — and collides at apply besides.
run "rejects_duplicate_principals_across_entries" {
  command = plan

  variables {
    access_entries = {
      readonly_team = {
        principal_arn = "arn:aws:iam::000000000000:role/shared-role"
        policy_associations = {
          view = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
            access_scope = { type = "namespace", namespaces = ["team-a"] }
          }
        }
      }
      quietly_admin = {
        principal_arn = "arn:aws:iam::000000000000:role/shared-role"
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
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
#
# The principal below is the PATH-STRIPPED spelling of the path-bearing
# ARN in the file-level stub: the same IAM role, a different string. A
# raw string compare would miss it, so this run is the regression for
# the guard's path/case normalization.
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

# Same role again, this time varying case — IAM role names are
# case-insensitive for uniqueness, so this is still one principal.
run "rejects_case_variant_of_the_cluster_stacks_principal" {
  command = plan

  variables {
    access_entries = {
      sso_admin = {
        principal_arn = "arn:aws:iam::000000000000:role/awsreservedsso_admin_ABCDEF1234567890"
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
