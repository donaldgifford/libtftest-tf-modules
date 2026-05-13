---
id: ADR-0003
title: "Pod Identity Agent installed on the addons module"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0003. Pod Identity Agent installed on the addons module

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
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

ADR-0002 commits the fleet to EKS Pod Identity as the credential-vending
mechanism for every addon, controller, and workload. That posture is only
realized once the `eks-pod-identity-agent` managed addon is installed on
the cluster — the agent is the DaemonSet that vends tokens at the
link-local address (`169.254.170.23`), and every
`aws_eks_pod_identity_association` in this repo is a no-op until it
exists.

ADR-0001 fixes the module-to-module contract: data flows through
`data.terraform_remote_state` against an S3 backend, with each module's
state file treated as a stable contract.

The fleet's standing operational order is:

1. **Cluster stack** — EKS control plane, KMS, SSO Access Entries,
   shared node SG, the five cluster-wide controller IAM roles.
2. **Node group stack(s)** — EKS managed node groups.
3. **Addons stack** — VPC CNI, kube-proxy, CoreDNS, EBS CSI (optional
   EFS CSI), with their per-addon Pod Identity Associations.
4. **Pod-identity stacks** — per-service / per-controller Pod Identity
   Associations as workloads come online.

That ordering is the load-bearing constraint here. Any module that
installs an `aws_eks_addon` whose underlying workload is a DaemonSet
(Pod Identity Agent, VPC CNI, EBS CSI, …) cannot apply cleanly before
node groups exist — `aws_eks_addon` waits for the addon to reach
`ACTIVE`, the DaemonSet has nowhere to schedule, the wait times out,
the apply fails. So agent install must happen no earlier than phase 3.

A prior draft of this ADR placed the agent in the cluster module on the
argument that "the agent must exist before any Pod Identity Association
is meaningful" is an invariant best published at the cluster's
remote-state boundary. That argument doesn't survive the operational
order: putting the agent in the cluster module would require the cluster
stack to apply *after* nodes — inverting the standard phase order — or
require a two-apply procedure on every fresh cluster (apply cluster
without the agent, apply nodes, re-apply cluster with the agent). Both
are operationally ugly enough that the invariant is better expressed in
a different state file.

## Decision

The `eks-pod-identity-agent` managed addon is installed by the **addons
module** (DESIGN-0003), alongside the rest of the EKS managed addons.
The cluster module (DESIGN-0002) does not install the agent.

Inside the addons module, the agent's `aws_eks_addon` resource is
applied first, and every other `aws_eks_addon` (VPC CNI, EBS CSI, EFS
CSI) `depends_on` it explicitly. This makes the "agent before
associations" invariant an intra-module ordering — visible in one
state file, enforced by Terraform's dependency graph:

```hcl
# modules/eks/addons/pod_identity_agent.tf

resource "aws_eks_addon" "eks_pod_identity_agent" {
  cluster_name                = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = var.pod_identity_agent_version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

# modules/eks/addons/vpc_cni.tf (and analogous for ebs_csi, efs_csi)

resource "aws_eks_addon" "vpc_cni" {
  # ...
  pod_identity_association {
    service_account = "aws-node"
    role_arn        = aws_iam_role.vpc_cni.arn
  }

  depends_on = [aws_eks_addon.eks_pod_identity_agent]
}
```

The agent has **no addon-level IAM role**. It uses
`eks-auth:AssumeRoleForPodIdentity` from the node role's
`AmazonEKSWorkerNodePolicy` (ADR-0002), so the `aws_eks_addon` block has
no `pod_identity_association` and no IAM resources backing it. It is the
simplest of the addons in this module.

**Agent version is pinned, not latest.** `var.pod_identity_agent_version`
has no default — the consuming Boilerplate-generated Terragrunt stack
must set an explicit version. Renovate watches the live repo and PRs
version bumps on its own cadence. This applies the same pinning
discipline to the agent that ADR-0002 implies for every other security-
sensitive addon: changes are deliberate and reviewable, not picked up
silently on the next apply.

## Consequences

### Positive

- **Matches the standing operational order.** Addons stack applies after
  the node group stack — by the time the agent is installed, there is
  always a node for its DaemonSet to schedule on. No two-apply
  bootstrap.
- **"Agent before associations" is intra-module and explicit.** Inside
  the addons module, every other `aws_eks_addon` `depends_on` the
  agent's resource. Terraform enforces the order at plan time. A
  downstream consumer reading `data.terraform_remote_state.eks_addons`
  is reading a state in which the agent is already part of the contract.
- **"All managed addons in one module" mental model survives.** No
  carve-out to remember; the agent is just the first one in the
  intra-module ordering.
- **Cluster module stays minimal.** Cluster stack's responsibility is
  control plane + identity scaffolding (KMS, SSO, controller IAM roles,
  node SG). It does not own anything node-dependent.
- **Pinning + Renovate.** Agent version churn is visible in the live
  repo, not absorbed silently by `null = latest`.

### Negative

- **Pod-identity-access stacks (phase 4) must read agent presence from
  the addons module's state, not the cluster module's.** Concretely:
  if a downstream stack wants to assert "Pod Identity is functional on
  this cluster," it reads
  `data.terraform_remote_state.eks_addons.outputs.pod_identity_agent_addon_arn`
  — if the addons module hasn't applied (or removed the agent), the
  output isn't present and the consumer's plan fails. Two state files
  to validate the same invariant, but each one owns the part of it that
  actually lives there.
- **Addons module gains one more resource and a `depends_on` edge.**
  Minor — the module already owns five addons; the agent is the sixth.

### Neutral

- The PrivateLink endpoint requirement
  (`com.amazonaws.<region>.eks-auth` in private subnets) does not change
  with the agent's location — it's owned by the VPC stack regardless.
  Documented in the addons module's README rather than the cluster
  module's.
- A future requirement to install a *different* DaemonSet-based addon
  before node groups exist would force a new pattern (likely a separate
  "post-nodes bootstrap" stack). Not foreseen for this fleet.

## Alternatives Considered

**Install the agent in the cluster module.** Tidier
"agent-presence-is-part-of-cluster-readiness" contract — a single state
file says "Pod Identity is functional." Rejected because the operational
order applies cluster before nodes, and `aws_eks_addon` for the agent
hangs without nodes. Workarounds (two-phase apply with a toggle, a
separate bootstrap module split off the cluster module, etc.) introduce
process or structural cost that outweighs the contract-cleanliness gain.
This was the prior draft of this ADR; the order constraint flipped it.

**Install the agent as a self-managed Helm chart or manifest in node
group user data.** Rejected: AWS publishes a managed addon explicitly so
that lifecycle, version, and conflict resolution are handled by EKS.
Self-managed throws away that infrastructure and ties the agent's
lifecycle to node group recreation.

**Create a separate `eks-bootstrap` stack between nodes and addons that
owns only the agent.** Rejected: one resource doesn't justify a stack.
The addons module is the right boundary because every other addon in
that module also `depends_on` the agent — intra-module ordering already
expresses the relationship cleanly.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- ADR-0002 — Node IAM minimization via Pod Identity (the agent's
  permissions come from the node role per this ADR, not from an
  addon-level role).
- ADR-0004 (forthcoming) — Addon-managed Pod Identity Association
  pattern. Builds directly on this ADR: every PIA in the addons module
  depends on the agent installed here.
- DESIGN-0002 — EKS Cluster Module (does not install the agent; node SG
  + KMS + controller IAM only).
- DESIGN-0003 — EKS Addons Module (installs the agent and the
  AWS-credentialed addons; migration sequencing for brownfield
  clusters lives in its Migration / Rollout Plan section).
- AWS docs — EKS Pod Identity Agent setup:
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html>
- `AmazonEKSWorkerNodePolicy` (includes
  `eks-auth:AssumeRoleForPodIdentity`):
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEKSWorkerNodePolicy.html>
