#--------------------------------------------------------------
# User data — AL2023 nodeadm + gVisor install (Phase 4)
#--------------------------------------------------------------
#
# Rendered multipart MIME body for aws_launch_template.node.user_data.
# Cluster identity comes from the cluster module's remote state (read
# at the use site per ADR-0001) — no aliasing local.
#
# The containerd_pull_through_mirror block is off-by-default per
# IMPL-0005 Q8. When enabled, the rendered template adds a
# /etc/containerd/certs.d/<host>/hosts.toml entry per configured
# upstream, redirecting pulls through the cache URL prefix.
#
# workload_class + taint_enabled carry the class into the kubelet
# flags (DESIGN-0024 part 3, F8 site 3). Note the spelling split the
# template preserves: kubelet's --register-with-taints wants
# "NoSchedule" while the EKS API (aws_eks_node_group.taint.effect)
# wants "NO_SCHEDULE" — same taint, two spellings, both required.

locals {
  user_data_body = templatefile(
    "${path.module}/templates/user_data.sh.tftpl",
    {
      cluster_name            = data.terraform_remote_state.eks.outputs.cluster_name
      cluster_endpoint        = data.terraform_remote_state.eks.outputs.cluster_endpoint
      cluster_ca_data         = data.terraform_remote_state.eks.outputs.cluster_ca_data
      k8s_arch                = var.architecture.k8s_arch
      workload_class          = var.workload_class
      taint_enabled           = local.class_taint_enabled
      gvisor_arch             = var.architecture.gvisor_arch
      gvisor_version          = var.gvisor_version
      runsc_sha512            = var.gvisor_sha512.runsc
      shim_sha512             = var.gvisor_sha512.containerd_shim_runsc_v1
      extra_kubelet_args      = var.extra_kubelet_args
      mirror_enabled          = var.containerd_pull_through_mirror.enabled
      mirror_cache_url_prefix = try(var.containerd_pull_through_mirror.cache_url_prefix, "")
      mirror_upstreams        = try(var.containerd_pull_through_mirror.upstreams, [])
    },
  )
}
