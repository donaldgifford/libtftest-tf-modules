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

  # Standard Kubernetes node labels for every node in this group.
  # workload-class=<class> mirrors the class taint (above) so workloads
  # select the class they belong on. runtime=gvisor advertises the
  # syscall sandbox per ADR-0005. kubernetes.io/arch is the standard
  # arch label; matched against pod nodeAffinity in mixed-arch clusters.
  runtime_labels = merge(
    {
      "workload-class"     = var.workload_class
      "runtime"            = "gvisor"
      "kubernetes.io/arch" = var.architecture.k8s_arch
    },
    var.additional_labels,
  )
}
