#--------------------------------------------------------------
# Locals
#--------------------------------------------------------------
#
# Only meaningful computation lives here. Remote-state outputs and
# variable passthroughs are referenced at the use site per ADR-0001.

locals {
  # Standard Kubernetes node labels for every node in this group.
  # workload-class=secure mirrors the always-on NO_SCHEDULE taint
  # so only workloads opting in (via tolerations + the gvisor
  # RuntimeClass) land here. runtime=gvisor advertises the syscall
  # sandbox per ADR-0005. kubernetes.io/arch is the standard arch
  # label; matched against pod nodeAffinity in mixed-arch clusters.
  runtime_labels = merge(
    {
      "workload-class"     = "secure"
      "runtime"            = "gvisor"
      "kubernetes.io/arch" = var.architecture.k8s_arch
    },
    var.additional_labels,
  )
}
