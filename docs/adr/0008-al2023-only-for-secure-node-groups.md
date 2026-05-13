---
id: ADR-0008
title: "AL2023 only for secure node groups"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0008. AL2023 only for secure node groups

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

The secure managed-node-group module (DESIGN-0001) derives `ami_type`
from `var.architecture`, producing either `AL2023_ARM_64_STANDARD` or
`AL2023_x86_64_STANDARD`. The choice of AMI family is the question
this ADR settles.

EKS managed node groups today support several AMI families:

- **AL2023** (`AL2023_*_STANDARD`) — Amazon Linux 2023, the current
  default. Ships containerd 1.7+, kernel 6.1, `nodeadm` bootstrap, and
  a config-drop-in pattern (`/etc/containerd/config.d/`).
- **AL2** (`AL2_*`, deprecated) — Amazon Linux 2, the historical
  default. AWS extended-support pricing applies after the standard EOL
  window; new Kubernetes versions no longer publish an AL2 AMI on the
  same cadence as AL2023.
- **Bottlerocket** (`BOTTLEROCKET_*`) — AWS's container-optimized OS
  with read-only root filesystem, dm-verity, A/B updates, minimal
  package set. Supports gVisor.
- **Custom AMI** (`CUSTOM`) — operator-built AMI, with user-data
  responsibility for bootstrap.

The module's user data is written against AL2023's specifics:

- It uses the `/etc/containerd/config.d/` drop-in directory, which
  requires containerd 1.6+ with `imports` support. AL2023 ships
  containerd 1.7+. AL2's containerd is older and would need direct
  edits to `/etc/containerd/config.toml`, which fights with AWS's
  AL2-side management of that file.
- It assumes `nodeadm` as the bootstrap path. AL2023 uses `nodeadm`;
  AL2 uses the older `/etc/eks/bootstrap.sh` script. The two differ
  in how kubelet flags, cluster endpoint, and CA data are passed.
- It downloads the official gVisor `runsc` binary at first boot and
  installs it to `/usr/local/bin/`. The path and the systemd unit
  expectations align with AL2023's filesystem layout.

Bottlerocket is structurally different from AL2023:

- Read-only root filesystem. There is no `/usr/local/bin/` to drop a
  `runsc` binary into via user data. gVisor enablement on Bottlerocket
  is via a *settings change* in the Bottlerocket TOML
  (`settings.kubernetes.container-runtime`) and an image variant that
  ships with `runsc` already installed, not via user-data binary drop.
- The "bootstrap container" model replaces user data. Custom bootstrap
  is delivered as an OCI image, not a shell script.
- API surface to the host is the Bottlerocket API, not file
  manipulation. Editing `/etc/containerd/config.d/runsc.toml` is not a
  thing you do on Bottlerocket.

In other words: the AL2023 vs Bottlerocket choice is not "swap the
`ami_type` string." It's a different user-data model, a different
bootstrap path, a different gVisor installation mechanism, and a
different operating-system contract. Supporting both inside this
module would mean templating two completely different user-data shapes
and gVisor-install paths, plus testing both. That is a meaningful
module-level cost.

This ADR's scope is the AMI family for *this* module — the secure
managed-node-group with the gVisor-on-AL2023 shape specified in
DESIGN-0001 §"Launch template hardening" and §"User data". A separate future module variant (or a separate ADR) can
introduce a Bottlerocket secure node group when there is a workload
class that justifies the cost.

## Decision

The secure managed-node-group module supports **AL2023 only**, in both
architectures (`AL2023_ARM_64_STANDARD` and `AL2023_x86_64_STANDARD`).
`var.architecture` derives the AMI type; there is no `var.ami_family`
or equivalent escape hatch.

Specifically:

- **AL2 is not supported.** AL2 is on extended support and will not
  receive new Kubernetes versions on the same cadence as AL2023. New
  modules should not anchor on it. Consumers still running AL2 on
  non-secure node groups elsewhere in the fleet are not affected by
  this module's choice; they migrate when they migrate.
- **Bottlerocket is not supported by this module.** A Bottlerocket
  secure-node-group is a viable future module variant — it has a real
  posture advantage (read-only root, dm-verity, A/B updates) that
  composes well with gVisor — but it is a separate module shape, not
  a flag on this one. If/when the workload class justifies it, a
  follow-up ADR will introduce that variant.
- **Custom AMIs are not supported.** Custom-AMI use requires the
  consumer to own the gVisor install + containerd-runtime registration
  + nodeadm bootstrap themselves; at that point the module's user data
  isn't doing anything useful. Out of scope.

The module's user data, drop-in path, and gVisor installation flow
target AL2023 exclusively. The `ami_type` value is derived from
`var.architecture` and is not independently configurable.

## Consequences

### Positive

- **One user-data path to template, not three.** The gVisor install
  script, the containerd drop-in, and the nodeadm bootstrap are all
  AL2023-shaped. Adding an AL2 path or a Bottlerocket path would
  multiply the user-data templates by the number of AMI families
  supported.
- **Containerd config drop-in works cleanly.** AL2023 ships containerd
  1.7+ and supports `/etc/containerd/config.d/` imports natively. The
  user data drops a single TOML file there without fighting with the
  AWS-managed `/etc/containerd/config.toml`. The drop-in directory
  requires containerd 1.6+ with `imports` support — AL2023 satisfies
  this, AL2 does not.
- **`nodeadm` bootstrap is the modern path.** Cluster endpoint, CA
  data, kubelet flags, and extra config are passed through `nodeadm`
  consistently. AL2's `/etc/eks/bootstrap.sh` is an older interface;
  not modeling it simplifies the launch-template templating.
- **Aligned with EKS's forward direction.** AWS treats AL2023 as the
  default AMI family for new node groups in 2026. New AMI features,
  new Kubernetes-version AMIs, and new addon compatibility land on
  AL2023 first.
- **Kernel 6.1+ gives gVisor a recent host kernel.** The `systrap`
  platform's syscall-interception path benefits from a current
  kernel. AL2's 5.10 kernel would also work but is older.

### Negative

- **No path to Bottlerocket from this module.** Operators who want
  Bottlerocket's read-only-root posture on top of gVisor must wait
  for the Bottlerocket variant module, or instantiate Bottlerocket
  outside this module. Acknowledged as a real gap, just not one this
  module closes.
- **Operators with AL2-pinned dependencies cannot use this module.**
  Some legacy node-side agents are AL2-only (rare in 2026, but real).
  Those nodes don't go on the secure node group; they stay on whatever
  AL2 node group they already run on, outside this module's scope.
- **Module evolution is tied to AL2023's evolution.** If AWS changes
  the AL2023 user-data interface, the AL2023 containerd layout, or the
  AL2023 nodeadm contract, this module's user data has to follow.
  Reasonable; the alternative (custom AMI) is worse.

### Neutral

- **The decision is per-module, not fleet-wide.** Other node groups in
  the fleet that aren't secure-workload-class can be on any AMI family
  appropriate to their use. This ADR does not deprecate AL2 elsewhere.
- **Bottlerocket variant is a follow-up, not a foreclosure.** The
  posture case for Bottlerocket + gVisor is real. The work to support
  it is a separate module (or a separate `variants/` shape) — not a
  decision this ADR rules out.
- **AMI version pinning is a separate question.** This ADR commits to
  the AL2023 *family*; the specific AMI release ID is selected by EKS
  managed node groups themselves (via `release_version`, optional) and
  controlled per consumer if needed. Pinning is hoisted to the
  consuming Terragrunt stack per ADR-0001.

## Alternatives Considered

**Support AL2 as a fallback.** Rejected because:

- AL2 is on extended support and will not receive new Kubernetes-
  version AMIs on the same cadence as AL2023. Anchoring a *new*
  module on an EOL-track AMI family is the wrong direction.
- AL2's containerd version doesn't reliably support the
  `/etc/containerd/config.d/` drop-in pattern, so the user data would
  need a separate code path that edits `/etc/containerd/config.toml`
  directly — fighting with AL2's own management of that file.
- AL2's bootstrap path (`/etc/eks/bootstrap.sh`) is different from
  AL2023's nodeadm, so the launch-template user data forks again.
- Two AMI families means two test matrices for libtftest. Cost has no
  payoff: workloads that genuinely need AL2 are not in this module's
  audience.

**Support Bottlerocket as an alternative AMI within this module.**
Rejected for this module, but viable as a *future separate module*.
Reasons not to fold it into this module:

- Bottlerocket has no `/usr/local/bin/` to drop `runsc` into via user
  data. gVisor enablement is via the Bottlerocket settings API and a
  pre-built variant image that bundles `runsc` — a different
  installation model entirely.
- Bootstrap is via bootstrap containers (OCI images), not shell user
  data. The module's `templates/user_data.sh.tftpl` doesn't translate.
- Host-side configuration is via the Bottlerocket API. Editing
  `/etc/containerd/config.d/` doesn't apply.

  These differences are large enough that a Bottlerocket variant is a
  different module's worth of work, not a flag. When the workload
  class genuinely needs Bottlerocket's read-only-root + dm-verity
  posture, the answer is to write that module. Until then, AL2023.

**Custom AMI (`ami_type = "CUSTOM"`) with consumer-owned bootstrap.**
Rejected. At that point the module's user data, containerd drop-in,
and gVisor install logic are doing nothing useful — the consumer is
re-implementing all of it. Custom-AMI usage belongs in a separate
escape-hatch module that doesn't pretend to install gVisor for you.

**Multiple AMI families gated by `var.ami_family`.** Rejected as
premature abstraction. There is one current AMI family the module
needs to support, and the cost of adding a second is paid in
user-data templating, containerd-config branching, bootstrap-path
branching, and test-matrix duplication. We're not paying that until
there's a concrete workload class that needs it.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`
  (AMI choice is a module-level posture, not hoisted to Boilerplate;
  consumers don't get to override it within this module).
- ADR-0005 — gVisor as the syscall sandboxing runtime (the
  installation flow this module ships is AL2023-shaped).
- ADR-0006 — ARM64 Graviton as default (the AMI variant ARM64 maps to
  is `AL2023_ARM_64_STANDARD`).
- ADR-0007 — IMDS hop limit 2 with minimal node IAM (launch-template
  metadata options, AL2023-agnostic but documented in the same launch
  template).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where
  the AL2023-specific user data, drop-in path, and nodeadm
  assumptions live).
- EKS AL2023 nodeadm bootstrap:
  <https://awslabs.github.io/amazon-eks-ami/nodeadm/>
- EKS AMI types:
  <https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-amis.html>
- Bottlerocket OS:
  <https://aws.amazon.com/bottlerocket/>
- AL2 extended support timeline:
  <https://docs.aws.amazon.com/linux/al2/ug/al2-eol.html>
