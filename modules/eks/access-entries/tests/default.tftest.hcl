# Plan-time invariants for the generic access-entry surface —
# IMPL-0020 Phase 4 (DESIGN-0024 part 1).
#
# The hub-shaped run below is the platform DESIGN-0001 §4 trio: the
# argocd-deployer's assumed sse-platform-access role, break-glass SSO,
# and the deploy role. Those three are the reason this module exists,
# so they are what the suite pins.
#
# Stubs (override_data): data.terraform_remote_state.eks — the cluster
# module's contract, including the sso_principal_arn output that arms
# the cross-stack collision guard.

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
  tags = {
    Account     = "libtftest"
    ClusterName = "libtftest-cluster"
    Environment = "test"
  }
}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_name              = "libtftest-cluster"
      cluster_version           = "1.31"
      cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
      cluster_ca_data           = "Y2EtZGF0YQ==" # base64("ca-data")
      cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
      cluster_security_group_id = "sg-cluster-stub"
      node_security_group_id    = "sg-node-stub"
      kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
      sso_principal_arn         = "arn:aws:iam::000000000000:role/AWSReservedSSO_Admin_abcdef1234567890"
    }
  }
}

# The platform §4 trio, as a live-repo stack would declare it.
run "hub_shaped_entries" {
  command = plan

  variables {
    access_entries = {
      argocd_deployer = {
        principal_arn     = "arn:aws:iam::111111111111:role/sse-platform-access"
        kubernetes_groups = ["deploy"]
        user_name         = "argocd-deployer"
      }
      break_glass = {
        principal_arn = "arn:aws:iam::000000000000:role/BreakGlassAdmin"
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          }
        }
      }
      deploy_role = {
        principal_arn = "arn:aws:iam::000000000000:role/deploy-role"
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          }
          app_ns = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = {
              type       = "namespace"
              namespaces = ["apps", "platform"]
            }
          }
        }
      }
    }
  }

  assert {
    condition     = length(aws_eks_access_entry.this) == 3
    error_message = "one access entry per map key"
  }

  # Logical names are the addresses — re-pointing a principal must not
  # move the resource.
  assert {
    condition     = aws_eks_access_entry.this["argocd_deployer"].principal_arn == "arn:aws:iam::111111111111:role/sse-platform-access"
    error_message = "the entry is addressed by logical name and carries the direct principal ARN (cross-account, so no in-account resolution)"
  }

  assert {
    condition     = aws_eks_access_entry.this["argocd_deployer"].cluster_name == "libtftest-cluster"
    error_message = "cluster_name must come from data.terraform_remote_state.eks.outputs.cluster_name (ADR-0001)"
  }

  assert {
    condition     = contains(aws_eks_access_entry.this["argocd_deployer"].kubernetes_groups, "deploy")
    error_message = "kubernetes_groups must bind the RBAC group the platform's deploy flow expects"
  }

  assert {
    condition     = aws_eks_access_entry.this["break_glass"].type == "STANDARD"
    error_message = "entry type defaults to STANDARD"
  }

  # Flattened "<entry>:<assoc>" addressing: three associations across
  # two entries, each independently addressable.
  assert {
    condition     = length(aws_eks_access_policy_association.this) == 3
    error_message = "one policy association per (entry x association) pair"
  }

  assert {
    condition     = aws_eks_access_policy_association.this["deploy_role:app_ns"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
    error_message = "associations are addressed \"<entry>:<association>\" so adding one never churns a sibling"
  }

  assert {
    condition     = aws_eks_access_policy_association.this["deploy_role:app_ns"].access_scope[0].type == "namespace" && length(aws_eks_access_policy_association.this["deploy_role:app_ns"].access_scope[0].namespaces) == 2
    error_message = "namespace scope must carry its namespaces — the scoping the SSO path cannot express"
  }

  # Cluster scope must send no namespaces at all — the API rejects a
  # namespaces list on a cluster-scoped association, so the module
  # nulls it rather than sending an empty list.
  assert {
    condition     = aws_eks_access_policy_association.this["break_glass:admin"].access_scope[0].type == "cluster" && aws_eks_access_policy_association.this["break_glass:admin"].access_scope[0].namespaces == null
    error_message = "a cluster-scoped association must send no namespaces (null, not an empty list)"
  }

  # ADR-0020 key-template pin: the eks read must compose the contract key
  # <account_name>/<region>/eks/<cluster_name>/terraform.tfstate. The producer's live-repo directory must match.
  assert {
    condition     = data.terraform_remote_state.eks.config.key == "sandbox/us-east-1/eks/libtftest-cluster/terraform.tfstate"
    error_message = "eks remote-state read must compose <account_name>/<region>/eks/<cluster_name>/terraform.tfstate (ADR-0020 remote-state key contract)"
  }
}

# The empty default is a legitimate bring-up state, not an error: the
# stack exists before anyone is granted access.
run "empty_map_creates_nothing" {
  command = plan

  assert {
    condition     = length(aws_eks_access_entry.this) == 0 && length(aws_eks_access_policy_association.this) == 0
    error_message = "an empty access_entries map must create no resources"
  }
}

# Non-STANDARD entries describe compute, not principals — the API
# refuses groups/user_name/policies on them, so the module does too.
run "non_standard_entry_type_is_bare" {
  command = plan

  variables {
    access_entries = {
      linux_nodes = {
        principal_arn = "arn:aws:iam::000000000000:role/node-role"
        type          = "EC2_LINUX"
      }
    }
  }

  assert {
    condition     = aws_eks_access_entry.this["linux_nodes"].type == "EC2_LINUX"
    error_message = "a bare non-STANDARD entry must plan cleanly"
  }
}
