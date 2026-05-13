---
id: ADR-0004
title: "Addon-managed Pod Identity Association pattern"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0004. Addon-managed Pod Identity Association pattern

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [Requirements for adding a new managed addon](#requirements-for-adding-a-new-managed-addon)
- [Consequences](#consequences)
  - [Positive](#positive)
  - [Negative](#negative)
  - [Neutral](#neutral)
- [Alternatives Considered](#alternatives-considered)
- [References](#references)
<!--toc:end-->

## Status

Accepted

## Context

Under ADR-0002, every EKS managed addon that needs AWS credentials gets
them through a Pod Identity Association on its service account. The
Terraform AWS provider exposes two distinct ways to create the
association:

1. **Standalone resource:** `aws_eks_pod_identity_association` —
   independent lifecycle, identified by its own `id`. The addon and the
   association are separate resources; either can be deleted without
   touching the other.
2. **Addon-managed block:** a `pod_identity_association { ... }` nested
   block *inside* `aws_eks_addon`. The association's lifecycle is owned
   by the addon resource — when the addon is deleted, the association
   goes with it. EKS exposes this via the addon API as a first-class
   property of the addon spec.

Both patterns produce identical runtime behavior — the agent sees the
same `(cluster, namespace, SA, role)` tuple regardless of which API
created it. The difference is purely in *lifecycle ownership* and what
that means for the Terraform state graph.

This ADR scopes only to the **addons module** (DESIGN-0003) — the
six EKS managed addons we install. The pod-identity-access module
(DESIGN-0004) is necessarily standalone because the workloads it grants
credentials to aren't EKS managed addons; that case is covered separately
(it can only use pattern 1).

## Decision

In the addons module (DESIGN-0003), the AWS-credentialed managed addons
(`vpc-cni`, `aws-ebs-csi-driver`, `aws-efs-csi-driver`) use the
**addon-managed `pod_identity_association` block** on their
`aws_eks_addon` resource. The standalone
`aws_eks_pod_identity_association` resource is *not* used in this
module.

```hcl
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name                  = "vpc-cni"
  addon_version               = var.vpc_cni_version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  pod_identity_association {
    service_account = "aws-node"
    role_arn        = aws_iam_role.vpc_cni.arn
  }

  depends_on = [aws_eks_addon.eks_pod_identity_agent]
}
```

The `eks-pod-identity-agent` addon itself has no `pod_identity_association`
block (it carries no addon-level IAM — see ADR-0002, ADR-0003).
`kube-proxy` and `coredns` have no block either (they need no AWS
credentials).

### Requirements for adding a new managed addon

Every addon in the module follows the same shape so that callers and
future contributors aren't reinventing the wiring. The agent is the
*only* unconditional addon — every other addon is gated by a per-addon
enable toggle (`count = var.<addon>_enabled ? 1 : 0`) applied
consistently to its `aws_eks_addon`, `aws_iam_role`, and
`aws_iam_role_policy_attachment`. Defaults vary (`vpc-cni` enabled by
default, `efs-csi` disabled by default, etc.); the *gating shape* is
uniform.

Adding a new managed addon to this module requires defining:

1. **Service account binding.** Namespace + service account that the
   AWS-shipped addon manifest creates. These are fixed by the addon
   implementation — operators don't choose them. Common defaults:
   - `vpc-cni` → `kube-system/aws-node`
   - `aws-ebs-csi-driver` → `kube-system/ebs-csi-controller-sa`
   - `aws-efs-csi-driver` → `kube-system/efs-csi-controller-sa`
   - `aws-mountpoint-s3-csi-driver` → `kube-system/s3-csi-driver-sa`
   - `amazon-cloudwatch-observability` → `amazon-cloudwatch/cloudwatch-agent`

   When unsure: `aws eks describe-addon-configuration --addon-name <name>
   --addon-version <ver> --query 'podIdentityConfiguration'` returns the
   addon-defined service account name authoritatively.
2. **IAM role + policy attachment.** A role whose assume-role policy
   trusts the EKS Pod Identity service principal
   `pods.eks.amazonaws.com` with `sts:AssumeRole` and `sts:TagSession` —
   the same universal Pod Identity trust policy used everywhere else in
   the fleet (ADR-0002). The AWS-managed policy attached (e.g.,
   `AmazonEKS_CNI_Policy`, `AmazonEBSCSIDriverPolicy`) is the one the
   addon's controller actually needs.
3. **Per-addon enable toggle.** A `var.<addon>_enabled` boolean with a
   sensible default. Gates the addon's resources via `count`.
4. **Per-addon version variable.** Pinned by Boilerplate; consumer
   passes the value (no `null = latest` defaults — same pattern as
   ADR-0003 for the agent).
5. **`pod_identity_association` block on the `aws_eks_addon`** carrying
   the `service_account` and the role's ARN. Plus the standard
   `depends_on = [aws_eks_addon.eks_pod_identity_agent]` from ADR-0003.

Template shape for a new addon, before filling in names:

```hcl
resource "aws_iam_role" "<addon>" {
  count              = var.<addon>_enabled ? 1 : 0
  name               = "${data.terraform_remote_state.eks.outputs.cluster_name}-<addon>"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "<addon>" {
  count      = var.<addon>_enabled ? 1 : 0
  role       = aws_iam_role.<addon>[0].name
  policy_arn = "arn:aws:iam::aws:policy/<ManagedPolicyName>"
}

resource "aws_eks_addon" "<addon>" {
  count                       = var.<addon>_enabled ? 1 : 0
  cluster_name                = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name                  = "<addon-name>"
  addon_version               = var.<addon>_version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  pod_identity_association {
    service_account = "<addon-sa-name>"
    role_arn        = aws_iam_role.<addon>[0].arn
  }

  depends_on = [aws_eks_addon.eks_pod_identity_agent]
}
```

## Consequences

### Positive

- **One Terraform resource per addon, not three.** Each AWS-credentialed
  addon collapses to a single `aws_eks_addon` + its IAM role + policy
  attachment, instead of `aws_eks_addon` + `aws_iam_role` +
  `aws_iam_role_policy_attachment` + a separate
  `aws_eks_pod_identity_association`. The dependency graph is smaller and
  the plan output is easier to read.
- **Cascading delete is what we want here.** Removing an addon from the
  cluster — say, swapping the EBS CSI driver for a different storage
  solution — should also remove the association the addon was bound to.
  Lifecycle coupling is a feature, not a bug, for managed addons. With
  the standalone resource, the operator has to remember to delete the
  association too.
- **AWS-aligned.** The `pod_identity_association` block on
  `aws_eks_addon` matches the EKS API's first-class
  `podIdentityAssociations` field. Operators looking at the AWS console
  or `aws eks describe-addon` output see the association where the API
  reports it.
- **Cleaner libtftest assertions.** Tests assert "the addon resource has
  a `pod_identity_association` block with these fields" in one place,
  rather than cross-correlating two separate resources by `cluster_name`
  + `namespace` + `service_account`.
- **Boilerplate-friendly.** Generating the addon stack from a single
  Boilerplate template is straightforward — one block per addon.

### Negative

- **Cannot bind a single role to multiple SAs from the addon block.**
  Each `pod_identity_association` block is one SA. For addons whose
  controller deployments use multiple service accounts that should
  share a role, this would force either multiple blocks (currently
  permitted — `pod_identity_association` is a repeating block) or
  switching to the standalone resource. Not a current concern for the
  six addons in scope, but worth noting.
- **Lifecycle coupling cuts both ways.** Recreating an addon —
  e.g., changing `addon_name` (not realistic) or running into a
  Terraform state issue that forces replacement — also recreates the
  association. In the meantime the controller pods AWS-call-loop with
  `AccessDenied` until the new association is consistent. Mitigated by
  Pod Identity's eventual-consistency window being short.

### Neutral

- The addon-managed pattern is only available for EKS managed addons.
  Workload-level grants (DESIGN-0004 — cert-manager, external-dns, ALB
  controller, application SAs) necessarily use the standalone
  `aws_eks_pod_identity_association` resource, because there is no
  parent `aws_eks_addon` for them. The two patterns coexist in the
  fleet by design.
- The IAM role itself is still a separate `aws_iam_role` resource —
  the addon-managed pattern only collapses the *association*, not the
  role + policy attachment.

## Alternatives Considered

**Standalone `aws_eks_pod_identity_association` for managed addons.**
The pre-2024 pattern, before AWS exposed the addon-level
`podIdentityAssociations` field. Rejected because:

- Cascading delete becomes a manual operator step. Removing the EBS CSI
  addon leaves an orphan `aws_eks_pod_identity_association` pointing at
  a service account that no longer has a controller.
- Two Terraform resources to manage per addon instead of one. More plan
  noise, more state to keep in sync.
- Doesn't match the EKS API's modeled relationship between addons and
  their associations.

The standalone resource is still the right answer when the bound
service account doesn't live behind an EKS managed addon — which is
exactly the workload-level case DESIGN-0004 handles.

**Mix both patterns inside the addons module** (some addons use the
block, others use standalone). Rejected: there's no reason any of our
managed addons should diverge. Uniform pattern across the module makes
the libtftest suite simpler.

## References

- ADR-0001 — Cross-module composition (single-purpose modules; minimal
  Terraform state per module favors fewer resources).
- ADR-0002 — Node IAM minimization via Pod Identity (the posture that
  requires the associations).
- ADR-0003 — Pod Identity Agent installed on the addons module
  (intra-module ordering; this ADR builds on it).
- DESIGN-0003 — EKS Addons Module (where this pattern lives).
- DESIGN-0004 — EKS Pod Identity Access Module (uses the standalone
  resource for workload-level grants, by necessity).
- `aws_eks_addon` `pod_identity_association` block:
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon#pod_identity_association>
- `aws_eks_pod_identity_association` resource:
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association>
- AWS docs — managed addons and Pod Identity:
  <https://docs.aws.amazon.com/eks/latest/userguide/add-ons-iam.html>
