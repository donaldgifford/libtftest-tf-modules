# Public-endpoint fence + bootstrap posture — IMPL-0020 Phase 3
# (DESIGN-0024 part 2 / INV-0011 OQ 12).
#
# The contract this file defends: endpoint_public_access = true and its
# implicit 0.0.0.0/0 fence are UNBROKEN. Nothing set must resolve to
# exactly the value already in every existing cluster's state, so the
# fence lands as a zero-diff replan — that invariant is the first run
# below, and it is the reason this whole surface is additive.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                = "libtftest"
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "stub-vpc"
  sso_cluster_policy  = "AmazonEKSViewPolicy"
  tags = {
    Account     = "libtftest"
    ClusterName = "libtftest"
    ClusterType = "eks"
    Environment = "test"
    Region      = "us-east-1"
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "000000000000"
    arn        = "arn:aws:iam::000000000000:user/test"
    user_id    = "test"
  }
}

override_data {
  target = data.terraform_remote_state.vpc
  values = {
    outputs = {
      vpc_id             = "vpc-libtftest"
      private_subnet_ids = ["subnet-private-libtftest-a", "subnet-private-libtftest-b"]
      public_subnet_ids  = ["subnet-public-libtftest-a", "subnet-public-libtftest-b"]
    }
  }
}

# THE zero-diff invariant. If this run ever fails, the fence stopped
# being additive and every existing cluster would replan.
run "default_fence_is_the_unbroken_contract" {
  command = plan

  assert {
    condition     = length(aws_eks_cluster.this.vpc_config[0].public_access_cidrs) == 1 && contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "0.0.0.0/0")
    error_message = "with no fence inputs the cluster must resolve to exactly [\"0.0.0.0/0\"] — the pre-DESIGN-0024 implicit value, so the change is zero-diff"
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == true && aws_eks_cluster.this.vpc_config[0].endpoint_private_access == true
    error_message = "the endpoint defaults (public + private both on) are unchanged by DESIGN-0024"
  }

  # DESIGN-0024 OQ 4: previously the provider default applied silently.
  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == true
    error_message = "bootstrap_cluster_creator_admin_permissions must be explicitly true (the pre-change effective value, now reviewable)"
  }

  # SSO off by default → the guard output is null and the consumer
  # module degrades to no-guard rather than erroring.
  assert {
    condition     = output.sso_principal_arn == null
    error_message = "sso_principal_arn must be null when sso_access_enabled is false"
  }

  # The SSO singleton's addresses are unchanged by this work — pinned
  # here so a future refactor of the access surface cannot quietly
  # move them out from under existing state.
  assert {
    condition     = length(aws_eks_access_entry.sso) == 0 && length(aws_eks_access_policy_association.sso) == 0
    error_message = "the SSO access-entry singleton must stay count-gated at its existing addresses"
  }
}

run "literal_cidrs_replace_the_default" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["203.0.113.0/24", "198.51.100.10/32"]
  }

  assert {
    condition     = length(aws_eks_cluster.this.vpc_config[0].public_access_cidrs) == 2
    error_message = "literal fence CIDRs must replace the 0.0.0.0/0 default, not append to it"
  }

  assert {
    condition     = contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "203.0.113.0/24") && contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "198.51.100.10/32")
    error_message = "both literal CIDRs must reach the cluster's public_access_cidrs"
  }

  assert {
    condition     = !contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "0.0.0.0/0")
    error_message = "a configured fence must not leave the world-open default in place"
  }
}

# Prefix lists are expanded at PLAN time — the data source is stubbed
# here exactly as the real expansion behaves.
run "prefix_list_entries_expand_into_the_fence" {
  command = plan

  variables {
    endpoint_public_access_prefix_list_ids = ["pl-corp"]
  }

  override_data {
    target = data.aws_ec2_managed_prefix_list.fence["pl-corp"]
    values = {
      id = "pl-corp"
      entries = [
        { cidr = "192.0.2.0/24", description = "corp egress a" },
        { cidr = "192.0.2.128/25", description = "corp egress b" },
      ]
    }
  }

  assert {
    condition     = length(aws_eks_cluster.this.vpc_config[0].public_access_cidrs) == 2
    error_message = "every prefix-list entry must expand into the fence"
  }

  assert {
    condition     = contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "192.0.2.0/24") && contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "192.0.2.128/25")
    error_message = "prefix-list CIDRs must reach the cluster's public_access_cidrs"
  }
}

# The effective fence is the union of both inputs, de-duplicated: a
# corp CIDR listed literally AND present in the prefix list must not
# consume two of the 40 slots.
run "union_of_both_inputs_is_deduplicated" {
  command = plan

  variables {
    endpoint_public_access_cidrs           = ["203.0.113.0/24", "192.0.2.0/24"]
    endpoint_public_access_prefix_list_ids = ["pl-corp"]
  }

  override_data {
    target = data.aws_ec2_managed_prefix_list.fence["pl-corp"]
    values = {
      id = "pl-corp"
      entries = [
        { cidr = "192.0.2.0/24", description = "also listed literally" },
        { cidr = "198.51.100.0/24", description = "prefix-list only" },
      ]
    }
  }

  assert {
    condition     = length(aws_eks_cluster.this.vpc_config[0].public_access_cidrs) == 3
    error_message = "the union must de-duplicate a CIDR present in both inputs (3 distinct, not 4)"
  }
}

# The spoke posture: private-only. Already mechanically possible before
# DESIGN-0024 — now coherent, since the guards reject the incoherent
# neighbours of this configuration.
run "private_only_spoke_posture" {
  command = plan

  variables {
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == false
    error_message = "a private-only spoke must plan with the public endpoint off"
  }
}

#--------------------------------------------------------------
# Guards (task 3.3)
#--------------------------------------------------------------

run "rejects_cluster_with_no_endpoint" {
  command = plan

  variables {
    endpoint_private_access = false
    endpoint_public_access  = false
  }

  expect_failures = [aws_eks_cluster.this]
}

run "rejects_fence_on_a_disabled_public_endpoint" {
  command = plan

  variables {
    endpoint_public_access       = false
    endpoint_public_access_cidrs = ["203.0.113.0/24"]
  }

  expect_failures = [aws_eks_cluster.this]
}

run "rejects_fence_over_the_forty_cidr_limit" {
  command = plan

  variables {
    # 41 distinct /32s — one past the EKS public-endpoint limit.
    endpoint_public_access_cidrs = [
      "203.0.113.1/32", "203.0.113.2/32", "203.0.113.3/32", "203.0.113.4/32",
      "203.0.113.5/32", "203.0.113.6/32", "203.0.113.7/32", "203.0.113.8/32",
      "203.0.113.9/32", "203.0.113.10/32", "203.0.113.11/32", "203.0.113.12/32",
      "203.0.113.13/32", "203.0.113.14/32", "203.0.113.15/32", "203.0.113.16/32",
      "203.0.113.17/32", "203.0.113.18/32", "203.0.113.19/32", "203.0.113.20/32",
      "203.0.113.21/32", "203.0.113.22/32", "203.0.113.23/32", "203.0.113.24/32",
      "203.0.113.25/32", "203.0.113.26/32", "203.0.113.27/32", "203.0.113.28/32",
      "203.0.113.29/32", "203.0.113.30/32", "203.0.113.31/32", "203.0.113.32/32",
      "203.0.113.33/32", "203.0.113.34/32", "203.0.113.35/32", "203.0.113.36/32",
      "203.0.113.37/32", "203.0.113.38/32", "203.0.113.39/32", "203.0.113.40/32",
      "203.0.113.41/32",
    ]
  }

  expect_failures = [aws_eks_cluster.this]
}
