#--------------------------------------------------------------
# Locals
#--------------------------------------------------------------
#
# Only meaningful computation lives here. Remote-state outputs and
# variable passthroughs are referenced at the use site per ADR-0001.

locals {
  # Per-class rules (DESIGN-0024 part 3). core is the untainted default
  # landing zone — the baseline platform workloads (ArgoCD, ESO, the
  # ALB controller) tolerate nothing and must schedule there. Every
  # other class carries workload-class=<class>:NO_SCHEDULE so only
  # workloads opting in via tolerations land on it.
  class_taint_enabled = var.workload_class != "core"

  # Effective gVisor: the class rule (secure sandboxes, nothing else
  # does) unless the caller overrides it either way. This single value
  # gates the install part, the runtime label, and the kubelet label
  # fragment together — the label must never advertise a sandbox the
  # node did not install, nor stay silent about one it did.
  gvisor_effective = coalesce(var.gvisor_enabled, var.workload_class == "secure")

  # Standard Kubernetes node labels for every node in this group.
  # workload-class=<class> mirrors the class taint (above) so workloads
  # select the class they belong on. runtime=gvisor advertises the
  # syscall sandbox per ADR-0005, and rides effective gVisor rather
  # than the class. kubernetes.io/arch is the standard arch label;
  # matched against pod nodeAffinity in mixed-arch clusters.
  runtime_labels = merge(
    {
      "workload-class"     = var.workload_class
      "kubernetes.io/arch" = var.architecture.k8s_arch
    },
    local.gvisor_effective ? { "runtime" = "gvisor" } : {},
    var.additional_labels,
  )

  # The kubelet --node-labels fragment, composed from the same rules as
  # runtime_labels above so the two label paths cannot drift. Scope
  # matches the pre-DESIGN-0024 behavior: the module-managed labels
  # only — var.additional_labels ride the EKS API path
  # (aws_eks_node_group.labels), not the bootstrap flags.
  kubelet_node_labels = join(",", concat(
    ["workload-class=${var.workload_class}"],
    local.gvisor_effective ? ["runtime=gvisor"] : [],
    ["kubernetes.io/arch=${var.architecture.k8s_arch}"],
  ))
}
