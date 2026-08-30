# Per-class workload matrix — DESIGN-0024 part 3 / IMPL-0020 Phase 1.
#
# The class parameterization replaced five hardwired "secure" sites
# (INV-0011 F8). This file is the matrix that pins every class's
# label + taint surface, including the explicit-secure run that keeps
# the pre-DESIGN-0024 posture asserted byte-for-byte after "core"
# became the default.
#
# Rendered user-data assertions (the kubelet label + taint fragments
# this class threading also drives) land in user_data.tftest.hcl with
# the gVisor gating — IMPL-0020 Phase 2, task 2.4.
#
# Stubs are file-level: every run in the matrix reads the same eks +
# vpc remote state, only var.workload_class changes.

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
  vpc_name            = "libtftest-vpc"
  nodegroup_name      = "libtftest-ng"
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
    }
  }
}

override_data {
  target = data.terraform_remote_state.vpc
  values = {
    outputs = {
      vpc_id             = "vpc-stub"
      private_subnet_ids = ["subnet-private-a", "subnet-private-b"]
      public_subnet_ids  = ["subnet-public-a", "subnet-public-b"]
    }
  }
}

# core — the default landing zone. Untainted by design: the platform
# baseline (ArgoCD, ESO, the ALB controller) tolerates nothing, so a
# taint here means nothing schedules on the hub.
run "class_core" {
  command = plan

  variables {
    workload_class = "core"
  }

  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "core"
    error_message = "workload-class label must carry the class (core)"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint : t if t.key == "workload-class"
    ]) == 0
    error_message = "core must be untainted — it is the default landing zone for baseline platform workloads"
  }

  assert {
    condition     = length(output.node_taints) == 0
    error_message = "node_taints output must be empty for core with no additional_taints"
  }

  assert {
    condition     = output.node_labels["workload-class"] == "core"
    error_message = "node_labels output must carry the class"
  }
}

# secure — the pre-DESIGN-0024 hardwired posture, now explicit. This
# run is the regression that keeps the highest-stakes class dialed:
# label + taint exactly as the module emitted them before the class
# parameterization landed.
run "class_secure" {
  command = plan

  variables {
    workload_class = "secure"
  }

  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "secure"
    error_message = "workload-class=secure label must be set for the secure class"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "secure" && t.effect == "NO_SCHEDULE"
    ]) == 1
    error_message = "secure must carry exactly the workload-class=secure:NO_SCHEDULE taint (the pre-DESIGN-0024 posture)"
  }

  assert {
    condition     = length(output.node_taints) == 1 && output.node_taints[0].key == "workload-class" && output.node_taints[0].value == "secure" && output.node_taints[0].effect == "NO_SCHEDULE"
    error_message = "node_taints output must carry the secure class taint"
  }
}

run "class_observability" {
  command = plan

  variables {
    workload_class = "observability"
  }

  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "observability"
    error_message = "workload-class label must carry the class (observability)"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "observability" && t.effect == "NO_SCHEDULE"
    ]) == 1
    error_message = "observability must carry the workload-class=observability:NO_SCHEDULE taint"
  }
}

# analytics — the pre-baked fifth class (INV-0011 OQ 13 as amended).
# Nothing runs on it yet; baking it now makes the future
# ClickHouse/Langfuse split a live-repo + chart change with no module
# release.
run "class_analytics" {
  command = plan

  variables {
    workload_class = "analytics"
  }

  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "analytics"
    error_message = "workload-class label must carry the class (analytics)"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "analytics" && t.effect == "NO_SCHEDULE"
    ]) == 1
    error_message = "analytics must carry the workload-class=analytics:NO_SCHEDULE taint"
  }
}

run "class_temporal" {
  command = plan

  variables {
    workload_class = "temporal"
  }

  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "temporal"
    error_message = "workload-class label must carry the class (temporal)"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "temporal" && t.effect == "NO_SCHEDULE"
    ]) == 1
    error_message = "temporal must carry the workload-class=temporal:NO_SCHEDULE taint"
  }
}

# Caller-supplied labels and taints layer on top of the class rules
# rather than replacing them — asserted on a tainted class so both the
# class taint and the caller's taint must be present.
run "layering_on_tainted_class" {
  command = plan

  variables {
    workload_class    = "observability"
    additional_labels = { "team" = "platform" }
    additional_taints = [{
      key    = "dedicated"
      value  = "thanos"
      effect = "PREFER_NO_SCHEDULE"
    }]
  }

  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "observability" && aws_eks_node_group.this.labels["team"] == "platform"
    error_message = "additional_labels must merge on top of the class label, not replace it"
  }

  assert {
    condition     = length(aws_eks_node_group.this.taint) == 2
    error_message = "a tainted class with one additional taint must emit exactly two taints"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "dedicated" && t.value == "thanos" && t.effect == "PREFER_NO_SCHEDULE"
    ]) == 1
    error_message = "additional_taints must be layered alongside the class taint"
  }

  assert {
    condition     = length(output.node_taints) == 2
    error_message = "node_taints output must report the class taint plus additional_taints"
  }
}

# Layering onto core: the caller's taints are still applied, but no
# class taint joins them.
run "layering_on_core" {
  command = plan

  variables {
    workload_class = "core"
    additional_taints = [{
      key    = "dedicated"
      value  = "build"
      effect = "NO_EXECUTE"
    }]
  }

  assert {
    condition     = length(aws_eks_node_group.this.taint) == 1
    error_message = "core with one additional taint must emit exactly that taint — no class taint"
  }

  assert {
    condition     = length(output.node_taints) == 1 && output.node_taints[0].key == "dedicated"
    error_message = "node_taints output on core must report additional_taints only"
  }
}

# The enum is closed on purpose: the platform owns which classes
# exist, so a caller string typo fails at plan instead of silently
# minting an unschedulable class.
# additional_labels merges last and wins on collision, but only on the
# EKS-API label path — the kubelet fragment is composed from the class
# rules alone. Overriding a managed key would make a node advertise
# something its bootstrap never applied; runtime=gvisor on a node with
# no runsc is exactly the lie the effective-gVisor rule exists to
# prevent, so the managed keys are reserved.
run "rejects_additional_labels_overriding_the_runtime_key" {
  command = plan

  variables {
    workload_class    = "analytics"
    additional_labels = { "runtime" = "gvisor" }
  }

  expect_failures = [var.additional_labels]
}

run "rejects_additional_labels_overriding_the_class_key" {
  command = plan

  variables {
    workload_class    = "core"
    additional_labels = { "workload-class" = "secure" }
  }

  expect_failures = [var.additional_labels]
}

run "rejects_unknown_class" {
  command = plan

  variables {
    workload_class = "monitoring"
  }

  expect_failures = [var.workload_class]
}
