# Rendered user-data assertions — IMPL-0020 Phase 2, task 2.4
# (DESIGN-0024 OQ 6a; mechanism per IMPL-0020 OQ 2a).
#
# The fleet's first coverage of a rendered template, landing exactly
# when that template stopped being static. Before DESIGN-0024 the
# kubelet flags carried two hardwired "secure" literals (INV-0011 F8
# sites 3) and the gVisor install part was unconditional (site 4);
# all three are now class-driven, and a regression in any of them is
# silent node-bootstrap breakage — the worst failure class to find at
# apply time.
#
# Mechanism: assert the launch template's user_data attribute
# directly, base64-decoded. The value is plan-known (templatefile
# renders from plan-known variables), so no output needs to widen the
# module's contract just to be testable.

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

# core: labelled with the class, NO taint registration, NO gVisor
# part, and no runtime label. This is the hub's default landing zone —
# if any of these four flip, nothing schedules on a fresh hub.
run "core_renders_untainted_and_gvisorless" {
  command = plan

  variables {
    workload_class = "core"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--node-labels=workload-class=core,kubernetes.io/arch=arm64")
    error_message = "kubelet --node-labels must carry the class and omit runtime= when gVisor is off"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "--register-with-taints")
    error_message = "core must not register any class taint at kubelet bootstrap"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "the gVisor install part must be absent from a core node's user data"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "io.containerd.runsc.v1")
    error_message = "the runsc containerd drop-in must be absent from a core node's user data"
  }

  # With neither gVisor nor the mirror enabled, the shellscript part
  # itself must not render at all — the MIME body is the NodeConfig
  # part plus the closing boundary.
  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "text/x-shellscript")
    error_message = "no shellscript MIME part may render when neither gVisor nor the mirror is enabled"
  }
}

# secure: the full pre-DESIGN-0024 rendered posture — class label,
# runtime label, the NoSchedule registration (kubelet's spelling), and
# the complete gVisor install.
run "secure_renders_full_gvisor_posture" {
  command = plan

  variables {
    workload_class = "secure"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--node-labels=workload-class=secure,runtime=gvisor,kubernetes.io/arch=arm64")
    error_message = "secure must render the pre-DESIGN-0024 kubelet label set (class + runtime + arch)"
  }

  # kubelet spells the effect NoSchedule; the EKS API side spells the
  # same taint NO_SCHEDULE. Both spellings are asserted (the API side
  # in workload_class.tftest.hcl) so neither silently drifts.
  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--register-with-taints=workload-class=secure:NoSchedule")
    error_message = "secure must register the class taint with kubelet's NoSchedule spelling"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "the gVisor install part must render for the secure class"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "io.containerd.runsc.v1")
    error_message = "the runsc containerd drop-in must render for the secure class"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "runsc runtime plugin not loaded after containerd restart")
    error_message = "the post-restart runsc plugin assertion must render alongside the install"
  }
}

# The three middle classes: tainted at kubelet bootstrap, class label
# present, no gVisor. Asserted per class because the taint fragment
# interpolates the class name into the flag.
run "observability_renders_tainted_without_gvisor" {
  command = plan

  variables {
    workload_class = "observability"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--register-with-taints=workload-class=observability:NoSchedule")
    error_message = "observability must register its class taint with kubelet"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--node-labels=workload-class=observability,kubernetes.io/arch=arm64")
    error_message = "observability must carry the class label without runtime="
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "observability must not install gVisor"
  }
}

run "analytics_renders_tainted_without_gvisor" {
  command = plan

  variables {
    workload_class = "analytics"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--register-with-taints=workload-class=analytics:NoSchedule")
    error_message = "analytics must register its class taint with kubelet"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "analytics must not install gVisor"
  }
}

run "temporal_renders_tainted_without_gvisor" {
  command = plan

  variables {
    workload_class = "temporal"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--register-with-taints=workload-class=temporal:NoSchedule")
    error_message = "temporal must register its class taint with kubelet"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "temporal must not install gVisor"
  }
}

#--------------------------------------------------------------
# Override direction runs (task 2.5)
#--------------------------------------------------------------

# gvisor_enabled = true on a non-secure class: the sandbox installs
# and the runtime label rides it, while the class taint stays the
# class's own (a sandboxed analytics pool, per the variable's docs).
run "gvisor_override_on_for_analytics" {
  command = plan

  variables {
    workload_class = "analytics"
    gvisor_enabled = true
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "gvisor_enabled = true must install gVisor on a non-secure class"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--node-labels=workload-class=analytics,runtime=gvisor,kubernetes.io/arch=arm64")
    error_message = "the runtime label must ride effective gVisor, not the class"
  }

  assert {
    condition     = aws_eks_node_group.this.labels["runtime"] == "gvisor"
    error_message = "the EKS-API label path must also advertise the runtime when gVisor is on"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "analytics"
    ]) == 1
    error_message = "the gVisor override must not disturb the class taint"
  }
}

# gvisor_enabled = false on secure: no install, and crucially no
# runtime label — a secure pool that is not sandboxed must not claim
# to be. The class taint is unaffected.
run "gvisor_override_off_for_secure" {
  command = plan

  variables {
    workload_class = "secure"
    gvisor_enabled = false
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "gvisor_enabled = false must suppress the install even on the secure class"
  }

  assert {
    condition     = !contains(keys(aws_eks_node_group.this.labels), "runtime")
    error_message = "a gVisor-disabled secure group must not advertise runtime=gvisor"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "--node-labels=workload-class=secure,kubernetes.io/arch=arm64")
    error_message = "the kubelet label fragment must drop runtime= when gVisor is overridden off"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "secure" && t.effect == "NO_SCHEDULE"
    ]) == 1
    error_message = "the gVisor override must not disturb the secure class taint"
  }
}

# The mirror is gated INDEPENDENTLY of gVisor. Before DESIGN-0024 both
# lived in one unconditional shellscript part; gating that whole part
# on gVisor would silently drop the pull-through mirror on every
# non-gVisor class. This run is that regression: core + mirror on.
run "mirror_renders_without_gvisor" {
  command = plan

  variables {
    workload_class = "core"
    containerd_pull_through_mirror = {
      enabled          = true
      cache_url_prefix = "000000000000.dkr.ecr.us-east-1.amazonaws.com"
      upstreams = [{
        host   = "docker.io"
        prefix = "docker-hub"
      }]
    }
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "/etc/containerd/certs.d/docker.io")
    error_message = "the pull-through mirror must render on a gVisor-less class — it is gated independently"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "enabling the mirror must not drag in the gVisor install"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "runsc runtime plugin not loaded after containerd restart")
    error_message = "the runsc plugin assertion belongs to the gVisor gate, not the shared shellscript part"
  }

  # The shared part still restarts containerd — the mirror wrote config
  # and needs it, exactly as gVisor does.
  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "systemctl restart containerd")
    error_message = "the shellscript part must restart containerd whenever it wrote containerd config"
  }
}
