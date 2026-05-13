---
id: DESIGN-0003
title: "EKS Addons Module"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---

<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0003: EKS Addons Module

**Status:** Accepted **Author:** Donald Gifford **Date:** 2026-05-13

<!--toc:start-->

- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module layout](#module-layout)
  - [Cross-module references](#cross-module-references)
  - [Pod Identity Agent (installed first)](#pod-identity-agent-installed-first)
  - [Addon resources — addon-managed Pod Identity Association pattern](#addon-resources--addon-managed-pod-identity-association-pattern)
  - [Addon version handling](#addon-version-handling)
  - [Conflict resolution](#conflict-resolution)
- [API / Interface Changes](#api--interface-changes)
  - [Required inputs](#required-inputs)
  - [Optional inputs](#optional-inputs)
  - [Outputs](#outputs)
- [Data Model](#data-model)
  - [Resource inventory](#resource-inventory)
  - [Required providers](#required-providers)
- [Testing Strategy](#testing-strategy)
  - [Static validation](#static-validation)
  - [libtftest plan-time / apply-time (LocalStack)](#libtftest-plan-time--apply-time-localstack)
  - [Integration (post-deploy)](#integration-post-deploy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Caveats](#caveats)
- [Open Questions](#open-questions)
  - [Resolved by ADRs](#resolved-by-adrs)
  - [Still open](#still-open)
- [References](#references)
  - [ADRs that constrain this module](#adrs-that-constrain-this-module)
  - [Sibling designs](#sibling-designs)
  - [External](#external)
  <!--toc:end-->

## Overview

A Terraform module that installs **every EKS managed addon** the cluster needs —
`eks-pod-identity-agent` (per ADR-0003), VPC CNI, kube-proxy, CoreDNS, EBS CSI
driver, and optionally EFS CSI driver — and provisions the Pod Identity
Associations that let those addons function with an empty node IAM role. The
secure node group (DESIGN-0001) cannot function usefully without this module
installed alongside it.

Inside the module, `eks-pod-identity-agent` is the first addon applied and every
other addon's `aws_eks_addon` declares an explicit `depends_on` relationship to
it — so "agent before associations" is intra-module ordering, enforced by
Terraform at plan time.

## Goals and Non-Goals

### Goals

- Install the **`eks-pod-identity-agent`** managed addon first (ADR-0003).
- Install the four other mandatory EKS managed addons (VPC CNI, kube-proxy,
  CoreDNS, EBS CSI) with version controls; each with an explicit `depends_on` to
  the agent.
- Optionally install EFS CSI driver.
- Create the IAM roles + Pod Identity Associations for the AWS-credentialed
  addons:
  - VPC CNI → SA `aws-node` in `kube-system` → `AmazonEKS_CNI_Policy`.
  - EBS CSI → SA `ebs-csi-controller-sa` in `kube-system` →
    `AmazonEBSCSIDriverPolicy`.
  - EFS CSI (when enabled) → SA `efs-csi-controller-sa` in `kube-system` →
    `AmazonEFSCSIDriverPolicy`.
- Use the **addon-managed Pod Identity Association pattern** (the
  `pod_identity_association` block inside `aws_eks_addon`, formalized in
  ADR-0004) so the association lifecycle is tied to the addon.
- Be safe to install on a cluster whose node group has an empty node role — this
  is the entire point of the module.

### Non-Goals

- Installing workload-controller addons like cert-manager, external-dns, or AWS
  Load Balancer Controller — those use the pod-identity-access module
  (DESIGN-0004) directly against their controller IAM roles (already output by
  the cluster module).
- Tuning CNI prefix delegation, CoreDNS replica counts, or other addon
  configuration beyond what `aws_eks_addon.configuration_values` exposes (v1
  scope).
- Provisioning the PrivateLink endpoint `com.amazonaws.<region>.eks-auth` that
  the Pod Identity Agent needs in private subnets — that's a VPC-stack concern,
  called out in this module's README as a hard prerequisite.

## Background

EKS managed addons run as DaemonSets / Deployments in `kube-system` and need AWS
credentials for non-trivial work. The legacy pattern attaches the policy to the
node IAM role, which means every container on the node inherits those
permissions. The Pod Identity pattern attaches the policy to the _addon's_
service account via a Pod Identity Association, so only the addon pods see those
credentials.

DESIGN-0001 §"Minimal node IAM" enumerates the policies the secure node group
does _not_ attach (CNI, EBS CSI, EFS CSI, CloudWatch agent, GuardDuty agent —
all per ADR-0002). This module is where those policies move _to_.

The ordering matters: if the addon comes up before its Pod Identity Association
exists, the addon's controller pods AWS-call-loop with `AccessDenied`. The
module enforces ordering via `depends_on`.

## Detailed Design

### Module layout

```sh
modules/eks/addons/
├── pod_identity_agent.tf # aws_eks_addon "eks-pod-identity-agent" — applied first
├── main.tf               # aws_eks_addon resources for kube-proxy, coredns
├── vpc_cni.tf            # IAM role + addon-managed PIA for aws-node
├── ebs_csi.tf            # IAM role + addon-managed PIA for ebs-csi-controller
├── efs_csi.tf            # IAM role + addon-managed PIA for efs-csi-controller (gated)
├── variables.tf
├── outputs.tf
├── versions.tf
```

### Cross-module references

The cluster's identifying outputs are read from the cluster module's remote
state, not passed in as inputs:

```hcl
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region = var.region
  }
}
```

Outputs are referenced at the use site (ADR-0001) —
`data.terraform_remote_state.eks.outputs.cluster_name` /
`...outputs.cluster_version` — no aliasing locals.

### Pod Identity Agent (installed first)

Per ADR-0003, this module installs the agent before any other addon and every
other addon explicitly depends on it:

```hcl
# pod_identity_agent.tf

resource "aws_eks_addon" "eks_pod_identity_agent" {
  cluster_name                = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = var.pod_identity_agent_version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}
```

The agent has **no addon-level IAM role**: it uses
`eks-auth:AssumeRoleForPodIdentity` inherited from the node role's
`AmazonEKSWorkerNodePolicy` (ADR-0002). No `pod_identity_association` block, no
`aws_iam_role`, no policy attachment.

`var.pod_identity_agent_version` has **no default** — the consumer
Boilerplate-generated Terragrunt stack must set an explicit pinned version
(ADR-0003). Renovate watches and PRs bumps.

### Addon resources — addon-managed Pod Identity Association pattern

We use the **addon-managed** Pod Identity Association pattern (ADR-0004): the
`aws_eks_addon` resource declares a `pod_identity_association` block directly,
tying the association lifecycle to the addon. When the addon is deleted or
recreated, the association goes with it.

```hcl
resource "aws_iam_role" "vpc_cni" {
  name               = "${data.terraform_remote_state.eks.outputs.cluster_name}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name                  = "vpc-cni"
  addon_version               = var.vpc_cni_version          # null = latest
  configuration_values        = var.vpc_cni_configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  pod_identity_association {
    service_account = "aws-node"
    role_arn        = aws_iam_role.vpc_cni.arn
  }

  depends_on = [aws_eks_addon.eks_pod_identity_agent]
}
```

Same pattern for `aws-ebs-csi-driver` (SA `ebs-csi-controller-sa`,
`AmazonEBSCSIDriverPolicy`) and `aws-efs-csi-driver` (SA
`efs-csi-controller-sa`, `AmazonEFSCSIDriverPolicy`, gated on
`var.efs_csi_enabled`) — both with the same `depends_on` to the agent. The
service-account names are fixed by the addon implementations — the AWS-shipped
manifests create them, so we don't need a Helm path.

`kube-proxy` and `coredns` are installed with no IAM at all — they operate
purely against the Kubernetes API — and also `depends_on` the agent. They don't
_use_ Pod Identity, but ordering them after the agent is free and keeps the
dependency graph regular.

The standalone `aws_eks_pod_identity_association` resource is _not_ used here —
it's reserved for workload-level grants where there's no parent `aws_eks_addon`
(DESIGN-0004 / ADR-0004 Alternatives).

### Addon version handling

Each addon has an `addon_version` input defaulting to `null`. When null, the
module resolves the latest version compatible with the cluster's Kubernetes
version via `data.aws_eks_addon_version`, inlined at the `aws_eks_addon`
resource:

```hcl
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  addon_version = coalesce(var.vpc_cni_version, data.aws_eks_addon_version.vpc_cni.version)
  # …
}
```

Pinning explicit versions in production is preferred — Renovate can keep them
current — but `null` is the right default for getting started.

### Conflict resolution

All addons use `resolve_conflicts_on_create = "OVERWRITE"` (in case anything
pre-existed) and `resolve_conflicts_on_update = "PRESERVE"` (don't blow away
user customizations to the kube-system manifests between apply cycles).

## API / Interface Changes

### Required inputs

| Input                        | Notes                                                                                                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `remote_state_bucket`        | S3 bucket holding the cluster module's state.                                                                                                              |
| `region`                     | Used in the remote state key and for AWS API calls.                                                                                                        |
| `cluster_name`               | Cluster name; used as the remote-state key fragment.                                                                                                       |
| `pod_identity_agent_version` | Pinned version of the `eks-pod-identity-agent` addon. No default — Boilerplate-generated Terragrunt passes the pinned value; Renovate bumps it (ADR-0003). |

`cluster_version` is read from the cluster's remote state (it's a stable
contract output of DESIGN-0002), not passed in directly.

### Optional inputs

| Input                          | Default | Notes                                 |
| ------------------------------ | ------- | ------------------------------------- |
| `vpc_cni_version`              | `null`  | Null → latest compatible.             |
| `vpc_cni_configuration_values` | `null`  | JSON string passed straight through.  |
| `kube_proxy_version`           | `null`  |                                       |
| `coredns_version`              | `null`  |                                       |
| `coredns_configuration_values` | `null`  | For replica count, etc.               |
| `ebs_csi_version`              | `null`  |                                       |
| `efs_csi_enabled`              | `false` | Gates the EFS CSI resources entirely. |
| `efs_csi_version`              | `null`  | Only used when enabled.               |
| `tags`                         | `{}`    |                                       |

### Outputs

| Output                         | Notes                                                                                                                            |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `pod_identity_agent_addon_arn` | Agent addon ARN. Consumers prove Pod Identity is functional by reading this; if the output is missing the read fails their plan. |
| `pod_identity_agent_addon_id`  | Agent addon ID for audit / debugging.                                                                                            |
| `vpc_cni_role_arn`             | For drift detection / external auditing.                                                                                         |
| `ebs_csi_role_arn`             |                                                                                                                                  |
| `efs_csi_role_arn`             | `null` when disabled.                                                                                                            |
| `addon_versions`               | Map of resolved versions actually applied.                                                                                       |

## Data Model

### Resource inventory

- `aws_eks_addon.eks_pod_identity_agent` (first, no `depends_on`)
- `aws_eks_addon.{vpc_cni, kube_proxy, coredns, ebs_csi_driver, efs_csi_driver[0]}`
  (each `depends_on` the agent)
- For each AWS-credentialed addon: `aws_iam_role` + 1×
  `aws_iam_role_policy_attachment` (the `aws_eks_pod_identity_association` is
  _inside_ the addon resource via the `pod_identity_association` block, not a
  separate resource — ADR-0004)
- `data.aws_eks_addon_version.*` for each addon with `version = null`

### Required providers

`hashicorp/aws ~> 6.2`. Terraform `>= 1.1`. **No `kubernetes` provider** — per
ADR-0011, Terraform modules in this repo manage AWS API resources only. Every
resource in this module is an `aws_eks_addon` + its IAM scaffolding; nothing
here touches the Kubernetes API.

## Testing Strategy

### Static validation

- `terraform validate` and `tflint` clean.
- `efs_csi_enabled = false` should not produce any EFS resources in plan.

### libtftest plan-time / apply-time (LocalStack)

- **Agent installed first, others depend on it.** Assert
  `aws_eks_addon.eks_pod_identity_agent` exists and has no `depends_on`; assert
  every other `aws_eks_addon` resource has `depends_on` that includes
  `aws_eks_addon.eks_pod_identity_agent`. _Most load-bearing ordering assertion
  in the suite_ (ADR-0003).
- **Agent version is pinned, not null.** Assert `var.pod_identity_agent_version`
  is non-empty and the addon's `addon_version` equals it.
- **Addon-managed Pod Identity Association.** For each AWS-credentialed addon,
  assert the `aws_eks_addon` resource carries a `pod_identity_association` block
  with the expected service account (`aws-node`, `ebs-csi-controller-sa`,
  `efs-csi-controller-sa`) and a matching `role_arn`.
- **Agent has no PIA, no IAM.** Assert `aws_eks_addon.eks_pod_identity_agent`
  has zero `pod_identity_association` blocks and no associated `aws_iam_role`.
- **Policy attachment correctness.** Assert the VPC CNI role has
  `AmazonEKS_CNI_Policy` attached and _only_ that policy; same for EBS CSI
  (`AmazonEBSCSIDriverPolicy`) and EFS CSI (`AmazonEFSCSIDriverPolicy`).
- **Trust policy.** Each addon role trusts `pods.eks.amazonaws.com` with
  `sts:AssumeRole` + `sts:TagSession`.
- **Remote-state read.** With a seeded fake cluster state in the test S3 bucket,
  the module's `data.terraform_remote_state` resolves `cluster_name` and
  `cluster_version`.
- **Version resolution.** With `vpc_cni_version = null` and a known
  `cluster_version`, the resolved version matches what
  `data.aws_eks_addon_version` returns.
- **Gating.** With `efs_csi_enabled = false`, plan contains no EFS CSI
  resources.

### Integration (post-deploy)

- `kubectl -n kube-system get pods -l k8s-app=aws-node` reaches `Running`.
- `kubectl -n kube-system get pods -l app=ebs-csi-controller` reaches `Running`
  — without an attached node-role CNI policy, this only works if the Pod
  Identity Association is correctly bound.
- A test PVC with `storageClassName: gp3` provisions a volume (validates the EBS
  CSI controller is actually authenticated).
- `aws eks describe-pod-identity-association --cluster-name <cluster> --association-id <id>`
  returns each expected binding.

## Migration / Rollout Plan

This module replaces the legacy pattern of attaching CNI / CSI policies to the
node IAM role. The migration on an existing cluster is delicate because the
addon needs working credentials during the cutover:

1. Install this module's IAM role + Pod Identity Association _before_ modifying
   node groups. The addon now has _two_ credential paths: node role (legacy) and
   Pod Identity (new). Either works; Pod Identity takes precedence.
2. Roll the node groups to the empty-IAM version (DESIGN-0001 enforces this by
   construction). Confirm addon pods continue to function — they're now using
   Pod Identity.
3. Remove the legacy node-role policy attachments (handled automatically by
   replacing the node group; nothing to do here).

For greenfield clusters there is no migration — install this module immediately
after the cluster module.

Rollback: temporarily re-attach `AmazonEKS_CNI_Policy` etc. to a working node
role and `terraform destroy` this module. Not expected to be needed for a
greenfield deployment.

## Caveats

- **PrivateLink endpoint.** Nodes in private subnets need
  `com.amazonaws.<region>.eks-auth` for the Pod Identity Agent to function. The
  VPC stack owns it, not this module. Without it, every addon's Pod Identity
  Association silently produces no credentials. See ADR-0003.
- **Eventual consistency.** Pod Identity Associations are eventually consistent
  — there can be a few-second delay after the API call. If an addon's controller
  pod starts within that window it may briefly fail to authenticate; the addon's
  own retry will recover. Same caveat applies to workload-level associations —
  see DESIGN-0004 §Caveats.
- **Brownfield migration.** `eksctl utils migrate-to-pod-identity` identifies
  existing IRSA roles, updates trust policies, and creates associations as a
  one-shot. Worth evaluating before doing manual migration in production. The
  per-cluster migration sequence (install agent → migrate addons
  lowest-risk-first → strip node-role policies) is captured in the §"Migration /
  Rollout Plan" below.

## Open Questions

### Resolved by ADRs

| Question                                  | Resolution                                                                                                                                                                    |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cross-module composition mechanism        | ADR-0001 — `terraform_remote_state` (S3); read cluster outputs at use site, no aliasing locals.                                                                               |
| Node IAM minimization                     | ADR-0002 — node role has two policies, every addon's AWS credential goes through a Pod Identity Association on its service account.                                           |
| Where the Pod Identity Agent lives        | ADR-0003 — this module installs the agent first; every other addon `depends_on` it. Agent version is pinned, no default.                                                      |
| Pod Identity Association resource pattern | ADR-0004 — addon-managed `pod_identity_association` block inside `aws_eks_addon`. Standalone `aws_eks_pod_identity_association` is reserved for DESIGN-0004 (workload-level). |
| AWS-only Terraform                        | ADR-0011 — no `kubernetes` provider; every resource here is an AWS API call.                                                                                                  |

### Still open

- **CoreDNS replica configuration.** `configuration_values` accepts JSON;
  whether to surface a typed input is a v1.x question. Currently free-form.
- **EFS CSI default.** Opt-in (`efs_csi_enabled = false`). Keep explicit per
  consumer; not auto-derived from node-group labels.
- **CoreDNS-as-DaemonSet (NodeLocal DNSCache).** Out of scope for v1; revisit if
  a high-throughput cluster demands it.
- **Brownfield migration tooling.** `eksctl utils migrate-to-pod-identity` vs
  Terraform-only cutover; tracked in the migration plan above, not a blocker for
  this design.

## References

### ADRs that constrain this module

- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- ADR-0002 — Node IAM minimization via Pod Identity (every policy that _would_
  land on the node role lands here instead, scoped per addon SA).
- ADR-0003 — Pod Identity Agent installed on the addons module (the intra-module
  ordering this design relies on).
- ADR-0004 — Addon-managed Pod Identity Association pattern
  (`pod_identity_association` block inside `aws_eks_addon`).
- ADR-0011 — RuntimeClass delivered out-of-band, not by Terraform (the
  AWS-only-Terraform principle this module also follows).

### Sibling designs

- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (this module is a
  precondition; secure node groups can't function usefully without it).
- DESIGN-0002 — EKS Cluster Module (provides the remote state this module reads;
  does _not_ install the agent — see ADR-0003).
- DESIGN-0004 — EKS Pod Identity Access Module (the workload-level counterpart;
  uses the standalone `aws_eks_pod_identity_association` resource for non-addon
  workloads).

### External

- EKS managed addons:
  <https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html>
- VPC CNI Pod Identity walkthrough:
  <https://docs.aws.amazon.com/eks/latest/userguide/cni-iam-role.html>
- EBS CSI driver Pod Identity walkthrough:
  <https://docs.aws.amazon.com/eks/latest/userguide/csi-iam-role.html>
- `aws_eks_pod_identity_association` resource (reference; not used in this
  module — see DESIGN-0004):
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association>
- `aws_eks_addon` `pod_identity_association` block (the pattern used here):
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon#pod_identity_association>
- `eksctl utils migrate-to-pod-identity`:
  <https://eksctl.io/usage/pod-identity-associations/>
