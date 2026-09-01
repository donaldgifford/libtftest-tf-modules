#--------------------------------------------------------------
# Managed Node Group — platform workload-class node group
#--------------------------------------------------------------
#
# DESIGN-0001 implementation per IMPL-0002, parameterized by workload
# class per DESIGN-0024 / IMPL-0020. Phases 1–4 of IMPL-0002 shipped
# the variable surface, IAM role + instance profile, launch template,
# and AL2023 nodeadm + gVisor user data. This file lands the node group
# itself: architecture-pinned ami_type (ADR-0006 / ADR-0008),
# ON_DEMAND default (ADR-0009), the class taint
# (workload-class=<class>:NO_SCHEDULE for every class but core),
# runtime + arch labels, and a precondition asserting the selected
# instance types match the chosen architecture.

resource "aws_eks_node_group" "this" {
  cluster_name    = data.terraform_remote_state.eks.outputs.cluster_name
  node_group_name = var.nodegroup_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  ami_type        = var.architecture.ami_type
  capacity_type   = var.capacity_type
  instance_types  = length(var.instance_types) > 0 ? var.instance_types : var.architecture.default_instance_types
  labels          = local.runtime_labels
  tags            = var.tags

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # Class taint matching the workload-class=<class> label — emitted for
  # every class except core, which is the untainted default landing
  # zone (DESIGN-0024 part 3). Workloads reach a tainted class through
  # the matching toleration; for secure that toleration rides the
  # gvisor RuntimeClass (DESIGN-0001 / ADR-0011).
  dynamic "taint" {
    for_each = local.class_taint_enabled ? [var.workload_class] : []
    content {
      key    = "workload-class"
      value  = taint.value
      effect = "NO_SCHEDULE"
    }
  }

  # Caller-supplied additional taints layered on top of the class taint.
  dynamic "taint" {
    for_each = var.additional_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  update_config {
    max_unavailable_percentage = 33
  }

  lifecycle {
    # Cluster autoscaler / Karpenter manages desired_size at runtime.
    # Without this Terraform fights the autoscaler on every plan.
    ignore_changes = [scaling_config[0].desired_size]

    # Plan-time guard against m7g-on-amd64 / m7i-on-arm64 / etc.
    # Cross-variable validation in variable.validation blocks needs
    # Terraform 1.9+; we pin >= 1.1 and use a resource precondition
    # instead. The regex is loose by design — caller-supplied families
    # that pin a single instance generation are accepted; obvious
    # cross-arch mistakes (m7g.* on amd64, m7i.* on arm64) are not.
    precondition {
      condition = alltrue([
        for t in(length(var.instance_types) > 0 ? var.instance_types : var.architecture.default_instance_types) :
        var.architecture.name == "arm64" ? !can(regex("^(m7i|c7i|m6i|c6i|t3|t3a|m5|c5)\\.", t)) : !can(regex("^(m7g|c7g|m6g|c6g|t4g)\\.", t))
      ])
      error_message = "instance_types contain at least one family incompatible with architecture.name=\"${var.architecture.name}\" (arm64 families: m7g/c7g/m6g/c6g/t4g; amd64 families: m7i/c7i/m6i/c6i/t3/t3a/m5/c5)."
    }
  }
}
