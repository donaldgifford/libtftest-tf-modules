# Apply against LocalStack — gap-discovery mode per RFC-0001 /
# IMPL-0020 Phase 5.
#
# Probes coverage for aws_eks_access_entry +
# aws_eks_access_policy_association, and proves live what the plan
# suite can only assert against stubs: that the cross-stack collision
# guard reads a real remote state, and that a pre-DESIGN-0024 cluster
# state degrades to no-guard rather than failing.
#
# REQUIRES LOCALSTACK PRO. EKS is not served by the token-free
# Community image at any version — probed directly on 4.4, which
# answers ListClusters with "The API for service 'eks' is either not
# included in your current license plan or has not yet been emulated"
# (FINDINGS.md). This is the same Pro requirement the three sibling
# eks consumers' tests-localstack/ suites already carry.
#
# Required env vars (the harness wiring terraform test needs to reach
# LocalStack):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# The `just tf test-localstack` recipe wires these for you.

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

# Declarations for the Terragrunt globals this file references via var.*
# in the setup run. Values come from the shared var-file
# (test/fixtures/terragrunt-inputs.tfvars) via the `just tf test*`
# recipes — no default here.
variable "region" {
  type = string
}

variable "remote_state_bucket" {
  type = string
}

variable "account_name" {
  type = string
}

variables {
  cluster_name       = "tftest-ae-cluster"
  stale_cluster_name = "tftest-ae-cluster-stale"
  tags = {
    Environment = "test"
  }
}

# Setup: VPC + cluster + principals + both stub state objects.
run "setup" {
  command = apply

  variables {
    remote_state_bucket = var.remote_state_bucket
    cluster_name        = var.cluster_name
    stale_cluster_name  = var.stale_cluster_name
    region              = var.region
    account_name        = var.account_name
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

# The hub-shaped apply: two entries, three associations across both
# scope types.
run "apply_entries" {
  command = apply

  variables {
    access_entries = {
      argocd_deployer = {
        principal_arn     = run.setup.deployer_role_arn
        kubernetes_groups = ["deploy"]
        user_name         = "argocd-deployer"
      }
      break_glass = {
        principal_arn = run.setup.break_glass_role_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          }
          app_ns = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = {
              type       = "namespace"
              namespaces = ["apps"]
            }
          }
        }
      }
    }
  }

  assert {
    condition     = length(aws_eks_access_entry.this) == 2
    error_message = "LocalStack must create one access entry per map key"
  }

  assert {
    condition     = length(aws_eks_access_entry.this["argocd_deployer"].access_entry_arn) > 0
    error_message = "LocalStack EKS must populate the access entry ARN"
  }

  assert {
    condition     = aws_eks_access_entry.this["argocd_deployer"].cluster_name == run.setup.cluster_name
    error_message = "the entry must attach to the cluster named by the remote state"
  }

  assert {
    condition     = length(aws_eks_access_policy_association.this) == 2
    error_message = "one association per (entry x association) pair must apply"
  }

  assert {
    condition     = aws_eks_access_policy_association.this["break_glass:app_ns"].access_scope[0].type == "namespace"
    error_message = "namespace-scoped associations must round-trip their scope through the API"
  }

  assert {
    condition     = length(output.access_entry_arns) == 2 && length(output.policy_association_ids) == 2
    error_message = "the pointer outputs must be populated after apply"
  }
}

# The guard against a REAL remote-state read: the fixture's stub names
# the SSO-owned role as the cluster stack's principal, so declaring it
# here must fail the plan phase of this apply.
#
# Note the PATH-STRIPPED spelling. The state object carries the
# path-bearing ARN IAM actually returns, so this run names the same
# principal by a different string — the live proof of the guard's
# normalization. A raw compare would let it through and the entry would
# collide at apply instead, which is the failure mode the guard exists
# to convert into a plan error. (Plan-only, so the stripped ARN is
# never sent to the API.)
run "collision_guard_rejects_the_cluster_stacks_principal" {
  command = plan

  variables {
    access_entries = {
      sso_admin = {
        principal_arn = run.setup.sso_owned_role_arn_path_stripped
      }
    }
  }

  expect_failures = [aws_eks_access_entry.this]
}

# Against the stale state object (no sso_principal_arn output), the
# same principal must apply cleanly — the try() degrade path, proven
# against a real S3 read rather than an override_data stub.
run "stale_state_degrades_to_no_guard" {
  command = apply

  variables {
    cluster_name = "tftest-ae-cluster-stale"
    access_entries = {
      sso_admin = {
        principal_arn = run.setup.sso_owned_role_arn
      }
    }
  }

  assert {
    condition     = aws_eks_access_entry.this["sso_admin"].principal_arn == run.setup.sso_owned_role_arn
    error_message = "a cluster state predating the sso_principal_arn output must degrade to no-guard, not fail"
  }
}
