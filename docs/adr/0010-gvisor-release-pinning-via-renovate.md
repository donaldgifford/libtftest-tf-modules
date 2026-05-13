---
id: ADR-0010
title: "gVisor release pinning via Renovate"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---

<!-- markdownlint-disable-file MD025 MD041 -->

# 0010. gVisor release pinning via Renovate

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

The secure managed-node-group module (DESIGN-0001) installs gVisor at node
first-boot from the official release URL:

```text
https://storage.googleapis.com/gvisor/releases/${gvisor_release}/${gvisor_arch}/runsc
```

`${gvisor_release}` is a Terraform input (`var.gvisor_release`). The gVisor
project publishes both a moving alias (`release/latest`, always the newest
stable release) and dated immutable tags (`release/YYYYMMDD.N`, never modified
after publication). The module currently defaults
`var.gvisor_release = "release/latest"` for getting-started ergonomics, but the
production posture is explicit: **`release/latest` is the wrong value for any
cluster doing real work.**

Two facts make this a load-bearing decision:

1. **The syscall implementation set changes between gVisor releases.** Every
   gVisor release can add, fix, or change behavior of syscalls the sentry
   implements. A workload that passed the eligibility evaluation procedure
   (ADR-0005; formalized in DESIGN-0001 §"Workload compatibility evaluation
   procedure") against release `20260301.0` is _not_ guaranteed to pass against
   release `20260408.0` — and certainly not against whatever `release/latest`
   resolves to on the next node provision. A `release/latest` pin means a
   previously-working workload can regress on the next Spot reclaim or
   autoscaler-triggered node replacement, without any explicit change anywhere
   in this repo.
2. **The install runs on node provision, not on Terraform apply.** The `runsc`
   binary is downloaded by user data at first boot. So the value of
   `var.gvisor_release` at the time of `terraform apply` is not the only thing
   that matters — the value of _the URL it resolves to when nodes provision_ is
   what determines which gVisor binary lands on the host. With `release/latest`,
   two nodes provisioned hours apart can run different gVisor versions in the
   same node group.

The third consideration is the operational shape of the fleet. ADR-0001 puts the
source-of-truth values in Boilerplate-generated Terragrunt
(infrastructure-live), with the module shipping safe getting-started defaults.
The fleet's standing pattern for dependency cadence is **Renovate against the
live repo**: Renovate watches dependency manifests, opens PRs with version
bumps, the team reviews and merges on its own cadence. ADR-0003 already applies
this pattern to the Pod Identity Agent addon version
(`var.pod_identity_agent_version` — pinned, no default).

This ADR aligns gVisor with the same pattern.

## Decision

`var.gvisor_release` is pinned in production to a dated immutable release tag
(e.g., `release/20260301.0`), set in the Boilerplate- generated Terragrunt
inputs at the consuming live-repo stack. The fleet uses an **org-wide pin** —
every secure node group across every cluster in every account runs the same
`gvisor_release` value at any given time. Renovate watches the gVisor release
feed and opens a single fleet-wide PR for each version bump.

The module's `var.gvisor_release` default remains `"release/latest"` for now to
keep getting-started friction low for non-production exploration (homelab /
scratch clusters / `terraform validate`). The default is _not_ the production
value; the production value is hoisted to the consuming Terragrunt stack, per
ADR-0001.

**Pinning discipline:**

- Production secure node groups MUST set `gvisor_release` to a dated immutable
  tag (`release/YYYYMMDD.N`). A consuming Terragrunt stack that omits
  `gvisor_release` and inherits the module default is out of compliance for
  production; CI in the live repo flags this.
- `release/latest` is permitted only for non-production usage. The module
  documentation calls out the production requirement explicitly.

**Org-wide cadence (Renovate-managed):**

- Renovate watches the gVisor release URL and opens a PR in the live repo per
  published release.
- The PR bumps a single Terragrunt-level variable that fans out to every secure
  node group instantiation. One value, one merge, fleet- wide propagation on the
  next apply cycle.
- Bumps go through the standard PR review path. Major-feature releases or
  release notes flagging syscall-set changes go through the
  workload-compatibility-evaluation procedure (ADR-0005; DESIGN-0001 §"Workload
  compatibility evaluation procedure") before merging.

**Rollout shape (out of scope for the module, documented here):**

- Apply the bump in dev clusters first, validate against the existing
  workload-compatibility evaluations recorded in workload repos.
- Promote to staging, then to prod, with the standing rollback path being
  "revert the Terragrunt commit, re-apply" — which downgrades the
  next-provisioned node to the previous tag without touching existing nodes'
  installed `runsc` binary.

## Consequences

### Positive

- **Behavior is deterministic across nodes and over time.** Every node in every
  secure node group across the fleet runs the same gVisor release at any given
  moment. A workload's compatibility evaluation (captured per ADR-0005 /
  DESIGN-0001 §"Workload compatibility evaluation procedure") stays valid
  against the pinned version until the team explicitly bumps it.
- **Version bumps are visible.** A Renovate PR in the live repo is the moment of
  decision; the team sees the release notes, decides whether to validate, and
  merges deliberately. No silent change on the next node provision.
- **Rollback is a Terragrunt revert.** Reverting the live-repo commit that
  bumped `gvisor_release` and re-applying restores the prior pin for
  newly-provisioned nodes. Existing nodes are unaffected (their `runsc` is
  already on disk). This is the cheapest possible rollback shape — no node
  replacement required for nodes that are already running.
- **Aligned with the rest of the fleet's pinning discipline.** ADR-0003 already
  pins the Pod Identity Agent the same way. ADR-0008 implies the same for AMI
  release pinning. Renovate-managed dated tags for security-sensitive components
  is the fleet's standing pattern.
- **One PR to bump, many clusters to roll.** Org-wide pin means the
  bump-and-merge cadence is one workflow, not one-per-cluster. Avoids fleet
  drift where different clusters run different sentry behaviors.

### Negative

- **The module's getting-started default (`release/latest`) is _not_ the
  production-correct value.** This is a small but real foot-gun: a consumer who
  instantiates the module without overriding `gvisor_release` inherits
  `release/latest`, which is the wrong posture for prod. Mitigated by live-repo
  CI gating, by the module README, and by the production-Terragrunt stacks
  always setting the variable. Not eliminated.
- **Renovate adds a PR queue to manage.** gVisor publishes releases roughly
  monthly. The team owns reviewing each bump. The cost is ~one PR per month per
  security-sensitive component (Pod Identity Agent already, gVisor now, EKS
  managed addons separately). Bounded but real.
- **Existing nodes don't get the new gVisor on a merge.** The bump takes effect
  at the _next_ node provision (Spot reclaim, autoscaler scale-up, manual node
  refresh, EKS managed-node-group AMI roll). Rolling a fleet to a new gVisor
  version is an EKS node-replacement operation, not a "bump and watch it
  propagate" operation. Standard for user-data-installed binaries; called out so
  it isn't surprising.

### Neutral

- **Per-cluster overrides are technically supported.** `var.gvisor_release` is a
  module input; a consumer can set a per-cluster value if there's a genuine
  reason (e.g., a specific cluster validating an upcoming bump ahead of fleet
  rollout). The org-wide default is the expectation, not a hard constraint at
  the module layer. Out-of-band pins are documented per-cluster.
- **The release URL is upstream-owned.** The fleet relies on
  `storage.googleapis.com/gvisor/releases/` being available at node provision
  time. A future air-gapped or supply-chain-conscious posture could mirror the
  binaries to an internal artifact store; that's a separate ADR (and a user-data
  rewrite) when the requirement appears.
- **SHA-512 verification stays.** The user data verifies the downloaded binary
  against its published `.sha512` regardless of whether the release tag is
  `latest` or dated. Pinning the release tag is about _what version_ gets
  installed; SHA-512 is about _is this binary the one the project published for
  that version_.

## Alternatives Considered

**Keep `var.gvisor_release = "release/latest"` as the production default.**
Rejected. Two same-node-group nodes provisioned hours apart can run different
gVisor versions; a workload's compatibility profile can change silently between
Spot reclaims. The latest-tracking pattern trades reviewability for "newest by
default," which is exactly the wrong tradeoff for a runtime that's load-bearing
for syscall isolation and whose syscall set changes between releases.

**Per-cluster pinning, no org-wide convention.** Each cluster's Terragrunt picks
its own `gvisor_release`. Rejected because fleet drift becomes the default:
clusters end up on different versions for no operational reason, and "what does
prod run?" becomes a multi-cluster question. The fleet's standing pattern
(ADR-0003 for Pod Identity Agent, addon versions in DESIGN-0003) is org-wide
Renovate-managed pinning. gVisor follows suit.

**Bake `runsc` into a custom AMI.** Pre-install the version at AMI build time
instead of downloading on user data. Rejected because ADR-0008 commits to AL2023
(no custom AMI). Custom-AMI work re-introduces every problem ADR-0008 was set up
to avoid (separate build pipeline, separate version-tracking pipeline, fleet of
AMIs to operate). The cost of the user-data download path (~30s at first boot)
is well-understood and acceptable.

**Build `runsc` from source against a pinned commit SHA.** Rejected as overkill.
The official release tags are signed and reproducible; SHA-512 verification of
the published binary against the published hash gives equivalent supply-chain
assurance without a build pipeline the team owns. Could be revisited if a future
compliance regime requires source-built artifacts.

**Mirror releases to an internal artifact store and pull from there.**
Reasonable for an air-gapped or supply-chain-conscious future posture. Out of
scope for this ADR — pulling from `storage.googleapis.com` is the current
posture for _all_ node-side binaries the fleet downloads at first boot, and
changing it for gVisor specifically is the wrong boundary. Would be a separate
fleet-wide ADR if the requirement appears.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state` (production
  values live in Boilerplate-generated Terragrunt; module defaults are
  getting-started values).
- ADR-0003 — Pod Identity Agent installed on the addons module (the precedent:
  pinned, no default, Renovate-managed bumps).
- ADR-0005 — gVisor as the syscall sandboxing runtime (the workload-
  compatibility evaluation procedure that pinning protects).
- ADR-0008 — AL2023 only (forecloses the bake-into-custom-AMI option).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where
  `var.gvisor_release` is declared and consumed; production posture documented
  under §"User data").
- gVisor releases page: <https://gvisor.dev/docs/user_guide/install/>
- Renovate (the fleet's standing dependency-bump pattern):
  <https://docs.renovatebot.com/>
