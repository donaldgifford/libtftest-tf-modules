---
id: ADR-0015
title: "Permit opt-in third managed policy on node role for ECR pull-through cache"
status: Proposed
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0015. Permit opt-in third managed policy on node role for ECR pull-through cache

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

Proposed. Amends [ADR-0002](0002-node-iam-minimization-via-pod-identity.md).

## Context

ADR-0002 commits the EKS node instance role to **two** AWS-managed policies
(`AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly`), plus
one optional toggleable extra (`AmazonSSMManagedInstanceCore` via
`var.enable_ssm`). Every other AWS credential a workload needs is granted
via an EKS Pod Identity Association on its Kubernetes service account.

DESIGN-0005 introduces an ECR **pull-through cache** to remove the
cluster's runtime dependency on direct Docker Hub / Quay / public-registry
pulls. The pull-through flow requires two ECR permissions on the **puller**
identity that `AmazonEC2ContainerRegistryPullOnly` does not include:

- `ecr:CreateRepository` — on the first pull of a new upstream image, ECR
  needs to materialize the local repository under the configured prefix
  (`mycache/library/nginx`).
- `ecr:BatchImportUpstreamImage` — the operation that lazy-fetches image
  layers from the upstream into ECR.

The puller is **containerd** (or kubelet, depending on the bootstrap
plumbing) running on the node, **not** a pod with a ServiceAccount.
Containerd uses the node IMDS / EC2 instance role to authenticate to
ECR — there is no ServiceAccount in scope, so Pod Identity is not an
option. The credential **must** be present on the node role itself for
pull-through to work.

This creates a tension with ADR-0002's two-managed-policies posture. The
options are:

1. **Add an opt-in third managed-style policy on the node role**,
   narrowly scoped to the two pull-through actions, behind an explicit
   flag. The node role is empty (per ADR-0002's spirit) when pull-through
   is not opted in; clusters that opt in pay a precisely-defined IAM
   increment.
2. **Skip pull-through cache entirely.** Accept Docker Hub anonymous
   rate limits (100 pulls / 6h / IP) as a reliability concern. Forfeits
   the operational and security benefits documented in DESIGN-0005
   §Background.
3. **Move the permissions to the cluster service role.** Mechanically
   broken — pull-through is invoked from the puller's credentials, not
   the cluster's, and the cluster service role is not in the puller's
   credential chain.

Option 1 is the only path that delivers DESIGN-0005's reliability +
security goals without abandoning ADR-0002's framing.

## Decision

ADR-0002 is amended to permit **one** narrowly-scoped, customer-managed
IAM policy as a **third** attachment on the node role, **opt-in by
default**, specifically and exclusively for ECR pull-through cache
permissions.

**Permitted policy shape:**

- Single `Allow` statement.
- Actions: exactly `ecr:CreateRepository` and
  `ecr:BatchImportUpstreamImage`.
- Resources: `arn:aws:ecr:${region}:${account_id}:repository/*` — bounded
  to the account and region, never `*` cross-account.

**Opt-in mechanics:**

- The policy is **emitted by the ECR pull-through cache module**
  (DESIGN-0005 / IMPL-0005) as the output
  `node_pull_through_policy_arn`, **gated** by
  `var.enable_node_pull_through_policy` (default `true` in the
  pull-through module — the module's reason to exist; clusters that
  don't want pull-through don't instantiate the module at all).
- The **attachment to the node role is opt-in at the consumer
  (Terragrunt) layer**, via the managed-node-group module's
  `var.extra_node_policies` input (default `[]` — empty list, no extra
  policies attached unless the consumer explicitly wires it).
- Two consents are therefore required for the pull-through IAM grant to
  reach a node role: (a) the pull-through cache module is instantiated
  in the account, **and** (b) the consumer's Terragrunt config passes
  the emitted ARN into the node-group module's `extra_node_policies`.
  Either consent alone is a no-op.

**Forbidden under this amendment:**

- Adding any policy on the node role that is **not** the
  exactly-scoped pull-through cache policy described above. ADR-0002's
  "Forbidden on the node role" list remains in force for everything
  else — CNI / EBS CSI / EFS CSI / CW Agent / GuardDuty / workload
  controller policies still move to Pod Identity, not the node role.
- Resource-wildcarding the policy beyond
  `arn:aws:ecr:${region}:${account_id}:repository/*`. No
  `arn:aws:ecr:*:*:repository/*`; no `*`; no cross-account.
- Action-extending the policy beyond `ecr:CreateRepository` and
  `ecr:BatchImportUpstreamImage`. If a future ECR pull-through feature
  requires additional actions, this ADR is re-opened.

**End state per cluster (amended from ADR-0002):**

- Two mandatory managed policies on the node role
  (`AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly`).
- Zero inline policies.
- Optionally `AmazonSSMManagedInstanceCore` (per ADR-0002, opt-in via
  `var.enable_ssm`).
- Optionally **one** customer-managed pull-through cache policy (per this
  ADR, opt-in via `var.extra_node_policies` containing
  `module.ecr_pull_through_cache.node_pull_through_policy_arn`).

## Consequences

### Positive

- DESIGN-0005's reliability + security benefits become accessible to
  clusters that want them — Docker Hub rate-limit immunity, AWS-native
  image scanning, VPC-routed image pulls — without breaking ADR-0002's
  framing for clusters that don't opt in.
- The IAM grant is precisely scoped: two actions, account+region-bounded
  resources, customer-managed (auditable in the account, not a black-box
  AWS-managed policy). Easier to review in an IAM audit than the
  broad AWS-managed alternatives.
- Two-stage opt-in (module instantiation + Terragrunt wiring) ensures the
  policy can never reach a node role by accident. Clusters that don't
  use pull-through cache stay at exactly the ADR-0002 baseline.
- The pull-through cache module remains fleet-shared / cluster-agnostic
  per DESIGN-0005 — it emits the policy ARN as an output; **attachment
  happens at the consumer layer**, not via cross-module remote-state
  coupling. Keeps the cluster ↔ node-group ↔ pull-through-cache modules
  independent in state.

### Negative

- ADR-0002's "exactly two managed policies" rule is no longer a strict
  invariant — readers must hold the amended posture in their head:
  "two mandatory + up to two opt-in." A bit more cognitive load when
  doing IAM audits.
- Drift risk: a future engineer might be tempted to add **more** opt-in
  policies under this same precedent ("ADR-0015 permitted one, so
  surely permitting two is fine"). This ADR is explicit that it
  permits **exactly one** policy, with **exactly two** actions, for
  **exactly** the pull-through cache use case. Any further amendments
  require their own ADR.
- The IAM policy exists in IAM even when not attached to any role (the
  pull-through cache module creates it as long as
  `enable_node_pull_through_policy = true`). Visible in the account
  inventory; mildly misleading if nothing actually attaches it. The
  alternative — emitting the policy document and attaching elsewhere —
  is more invasive to the consumer interface; this is the smaller cost.

### Neutral

- The IMDS hop-limit posture from ADR-0007 is unaffected — the
  pull-through cache puller already operates from the node role's
  credentials regardless of hop count, and the new policy doesn't widen
  the attack surface beyond what `AmazonEC2ContainerRegistryPullOnly`
  already concedes (containers escaping to IMDS could already pull from
  ECR; this ADR adds repository creation in the pull-through prefix and
  upstream-image import, neither of which is exfiltratable in a useful
  way).
- The containerd registry mirror configuration that **uses** the cache
  (IMPL-0002 Phase 4 / Q8) is a separate consent gate, also opt-in by
  default. A cluster can have the IAM policy attached without the
  containerd mirror configured, or vice versa — they're independently
  gated. See [IMPL-0005 Q8 / IMPL-0002 Q1](../impl/0005-ecr-pull-through-cache-module-implementation.md).
- ADR-0002's `var.enable_ssm` precedent for opt-in node-role additions
  is the same shape this ADR follows. Both opt-ins live at the
  managed-node-group module's input surface; both default to off.

## Alternatives Considered

**Strict ADR-0002 — refuse any third policy; skip pull-through cache.**
The conservative read. Accept Docker Hub rate limits, public-network
dependence on every cluster startup, and no AWS-side image scanning.
Rejected — DESIGN-0005's reliability concern is real (the parent org has
hit Docker Hub limits before) and the pull-through cache is the AWS-native
fix.

**Inline policy on the node role instead of a managed-style policy.**
Technically sidesteps the letter of "two managed policies" by attaching
an inline policy instead. Same blast radius, same actions, same scope —
just under a different IAM resource type. Rejected because it's a
distinction without a security difference and harder to audit (inline
policies don't appear in IAM's policy list view; they require role-level
inspection).

**Move pull-through permissions to a separate Pod Identity Association
on a pod-running-pull-through-shim service account.** Doesn't work
mechanically. The puller is **containerd**, which authenticates to ECR
via the instance role at the OS level, before any Kubernetes pod runs.
No ServiceAccount is in scope. Pod Identity is not in containerd's
credential chain.

**Use a registry mirror sidecar (e.g., Spegel, harbor-mirror) instead of
ECR pull-through cache.** Different solution to the same problem — caches
images at the K8s layer rather than the AWS layer. Trades off AWS-native
scanning and VPC-routed pulls for K8s-native simplicity. Out of scope for
this ADR; could coexist with pull-through cache in a future cluster
configuration without amendment.

**Attach the third policy at the cluster-module layer (via remote-state
read of the node role name).** Couples the ECR pull-through cache
module to the managed-node-group module's state, contradicting
DESIGN-0005's "fleet-shared, cluster-agnostic" framing. Rejected —
attachment at the Terragrunt consumer layer is the right boundary.

## References

- ADR-0002 — Node IAM minimization via Pod Identity (this ADR amends).
- ADR-0007 — IMDS hop limit 2 with minimal node IAM (unchanged by this
  amendment).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (consumer of
  the opt-in attachment via `var.extra_node_policies`).
- DESIGN-0005 — ECR Pull-Through Cache Module (the module that emits
  `node_pull_through_policy_arn`).
- IMPL-0002 — Managed Node Group Module Implementation (consumer-side
  wiring: `var.extra_node_policies`, default `[]`).
- IMPL-0005 — ECR Pull-Through Cache Module Implementation (emitter-side
  wiring: `var.enable_node_pull_through_policy`, default `true`; the
  policy resource itself).
- AWS docs — ECR pull-through cache IAM permissions:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html>
- AWS docs — `AmazonEC2ContainerRegistryPullOnly` policy reference:
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEC2ContainerRegistryPullOnly.html>
