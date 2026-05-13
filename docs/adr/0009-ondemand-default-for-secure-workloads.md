---
id: ADR-0009
title: "ON_DEMAND default for secure workloads"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0009. ON_DEMAND default for secure workloads

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

The EKS managed node group resource accepts `capacity_type` of
`ON_DEMAND` or `SPOT`. The choice trades raw $/vCPU (Spot wins by
50–70%) for interruption tolerance (Spot instances can be reclaimed
on 2-minute notice). The secure managed-node-group module
(DESIGN-0001) exposes `var.capacity_type` and needs to pick a default.

Two facts shape the answer for *this* module specifically:

1. **Workload class.** The secure node group exists for workloads
   where syscall-level isolation matters — multi-tenant code,
   untrusted third-party code, internal-build runners, anything where
   defense-in-depth at the runtime layer is the point. The workloads
   that opt into this node group are not, by definition, the class
   where "the pod just died, retry on a new node" is a cheap
   operation. Build runners get interrupted mid-build, multi-tenant
   workloads see customer-visible drops, internal-build pipelines
   replay from a checkpoint. The interruption cost is concretely
   non-zero.
2. **gVisor cold-start cost.** Every new node in the secure group
   runs the user-data bootstrap from ADR-0005's installation flow:
   download `runsc` + the containerd shim (~30s), verify SHA-512,
   install, drop in the containerd config, restart containerd. A
   Spot interruption that recycles a node pays this cost again every
   time. ON_DEMAND nodes pay it once and amortize for the node's
   lifetime. Spot-aggressive autoscaling on this node group makes the
   gVisor install path a hot loop.

Beyond those two, there's the standard tradeoff:

- **Spot capacity availability is uneven.** Graviton spot capacity
  varies by region and family — `c7g`/`m7g`/`r7g` Spot can be thin
  in specific regions/AZs, particularly in growth periods. x86_64
  Spot is generally deeper but still subject to family-wide
  reclaims.
- **PDBs and graceful drain help but don't eliminate cost.** Even
  with `PodDisruptionBudget` and a 2-minute interruption notice, the
  pod restarts somewhere — and "somewhere" in this module means
  another secure node, which means another gVisor install if no
  capacity is warm.
- **Dev environments are different.** A dev cluster running the
  secure node group for compatibility testing has very different
  cost sensitivity from prod. Forcing ON_DEMAND module-wide would
  make dev usage more expensive than it needs to be.

This ADR sets the *default*. `var.capacity_type` remains a first-class
input so consumers with explicit Spot tolerance — and the workload
shape that justifies it — can opt in.

## Decision

`var.capacity_type` defaults to `"ON_DEMAND"`. The validation accepts
`"ON_DEMAND"` or `"SPOT"`. Per-workload Spot opt-in is permitted by
overriding the input at the consuming Terragrunt stack.

The default applies uniformly across `arm64` and `amd64` instantiations
of the module. Capacity-type choice is architecture-agnostic; what
varies by architecture is *Spot capacity depth* (Graviton thinner,
x86_64 deeper), which is a separate-from-capacity-type concern handled
per-region by the consumer if they opt into Spot.

A consumer choosing `capacity_type = "SPOT"` is expected to:

- Configure `PodDisruptionBudget` on every workload on that node group.
- Run with `min_size >= 1` headroom so reclaim doesn't take the group
  to zero.
- Accept that gVisor bootstrap cost is paid per node replacement.
- Document the workload-level justification (cost-sensitivity vs
  interruption-tolerance) so future readers can see why this opt-in
  was taken.

The module does not gate on these — they're consumer-side disciplines,
not module-enforced. The default exists to make the safe choice the
default; the override exists to make the cost-sensitive choice
explicit.

## Consequences

### Positive

- **Workloads don't get cheaper and less reliable by accident.** The
  secure node group's workload class is the class where reliability
  matters most. Making Spot opt-in keeps the default behavior aligned
  with the "this is the *secure* node group" framing rather than the
  "this is the *cheap* node group" framing.
- **gVisor bootstrap cost is paid once per node.** ON_DEMAND nodes
  don't churn; the ~30s `runsc` install runs at first provision and
  then never again for that node's lifetime. Spot nodes pay it on
  every reclaim, which compounds when reclaim rates are high.
- **Graviton-default + ON_DEMAND-default composes cleanly.** ADR-0006
  defaults to Graviton, which has thinner Spot capacity. Defaulting
  to ON_DEMAND avoids the worst-case combination of (Graviton-Spot
  thin capacity) × (secure workload class).
- **Per-workload Spot opt-in stays viable.** Consumers with workloads
  that are genuinely interruption-tolerant (some CI runners, some
  batch workloads) can override `capacity_type` at the Terragrunt
  layer. The module doesn't foreclose the cheap option; it just
  doesn't pick it by default.

### Negative

- **Cost is higher than it could be for workloads that *would* tolerate
  Spot.** Dev clusters running compatibility tests against the secure
  node group pay ON_DEMAND prices by default. Consumers absorb this
  by overriding `capacity_type = "SPOT"` in dev Terragrunt; not free,
  but a one-line config change.
- **No mixed-capacity instance distribution at the module level.**
  AWS managed node groups don't natively support a mixed
  ON_DEMAND/SPOT distribution — `capacity_type` is one or the other
  per node group. Consumers wanting a mix instantiate the module
  twice, once per capacity type, with two distinct node groups in
  the same cluster.
- **A default isn't enforcement.** A consumer can flip
  `capacity_type = "SPOT"` without doing the disciplines listed in
  the Decision section. The module won't catch that. Module
  documentation calls them out; libtftest can assert *that the
  default is ON_DEMAND* but not *that a Spot opt-in is justified*.

### Neutral

- **The decision is per-workload at the consumer layer, not
  fleet-wide.** This ADR sets the module default; it does not
  prescribe Spot use anywhere else in the fleet. Non-secure node
  groups in other modules use whatever capacity strategy fits their
  workload class.
- **Capacity-rebalance behavior is out of scope.** EKS managed node
  groups handle Spot reclaim by replacing instances; this module
  doesn't add custom interruption-handler logic. Consumers opting
  into Spot can deploy `aws-node-termination-handler` separately if
  they want richer reclaim handling; that's a workload-cluster
  concern, not a module concern.

## Alternatives Considered

**Default `capacity_type = "SPOT"`.** The cost-aggressive default —
roughly 50-70% cheaper than ON_DEMAND. Rejected because:

- The secure node group's workload class is the class where
  interruption hurts most. "Cheap and unreliable" is the wrong
  default trade for the workloads this module exists to host.
- gVisor bootstrap is paid per node provision. Spot reclaim turns
  that ~30s install into a recurring tax proportional to the
  reclaim rate, which can dominate the cost savings.
- Graviton (the module's default architecture per ADR-0006) has
  thinner Spot capacity than x86_64 in many regions. The combination
  is the worst-case for "your secure pods just got reclaimed and
  there's no replacement capacity available."

**No default — require `capacity_type` to be set.** Force every
consumer to decide. Rejected: ON_DEMAND is the right answer for >90%
of secure-workload deployments. Making consumers type it adds friction
without buying any safety, the same reasoning as ADR-0006's default-
architecture decision.

**Two separate modules: `secure-nodegroup-ondemand` and
`secure-nodegroup-spot`.** Rejected — premature decomposition. The
*only* difference is one input value and the (consumer-side)
discipline around PDBs and graceful drain. Splitting the module
duplicates the launch template, IAM, user data, and RuntimeClass
plumbing for no module-level benefit. The consumer-side override is
the right granularity.

**Mixed `instance_distribution` via `aws_launch_template`'s mixed
instances policy.** Rejected because EKS managed node groups don't
honor a launch-template `instance_market_options` in the way
mixed-instances policies work in plain Auto Scaling Groups. EKS
managed node groups pin `capacity_type` at the node-group level, and
the cleanest way to get an ON_DEMAND+SPOT mix is two managed node
groups — which is what the consumer-side override accomplishes.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`
  (`capacity_type` is hoisted to Boilerplate-generated Terragrunt for
  prod consumers; the module default is the safe starting point).
- ADR-0005 — gVisor as the syscall sandboxing runtime (the
  bootstrap-cost-per-node argument that makes Spot expensive here).
- ADR-0006 — ARM64 Graviton as default (the architecture default
  whose thinner Spot capacity composes badly with `SPOT` here).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where
  `var.capacity_type` is declared and consumed by `aws_eks_node_group`).
- EKS managed node group capacity types:
  <https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html>
- EC2 Spot interruption behavior:
  <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html>
