---
id: ADR-0006
title: "ARM64 Graviton as default for secure workloads"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---

<!-- markdownlint-disable-file MD025 MD041 -->

# 0006. ARM64 Graviton as default for secure workloads

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

The secure managed-node-group module (DESIGN-0001) supports both ARM64 (AWS
Graviton) and x86_64 (Intel/AMD) via a single `architecture` input. The module
derives `AL2023_ARM_64_STANDARD` vs `AL2023_x86_64_STANDARD`, the gVisor binary
arch (`aarch64` vs `x86_64`), the Kubernetes arch label (`arm64` vs `amd64`),
and the default instance-type list from that input. EKS managed node groups are
single-AMI-type, so a single cluster that needs both architectures instantiates
the module twice — one node group per architecture.

The question this ADR settles is what the _default_ should be when a consumer
calls the module without specifying `architecture`. That default is also the
steer for new workloads: "start on Graviton unless you have a specific reason
not to."

Considerations on the table:

- **Cost.** Graviton families (`m7g`/`c7g`/`r7g`, and the newer
  `m8g`/`c8g`/`r8g`) price ~20% below their Intel/AMD counterparts at the same
  vCPU/RAM points, and frequently better than that on per-RPS throughput for
  syscall-light workloads.
- **gVisor compatibility.** The gVisor project publishes first-class `aarch64`
  binaries from the same release URL as `x86_64`, on the same cadence. The
  upstream gVisor syscall compatibility tables (linked in References)
  treat both arches as essentially equivalent for modern workloads — the
  "more syscalls" on x86 are legacy variants (`open`, `stat`, `fork`,
  `dup2`, `epoll_create`) that ARM64 already deprecated in favor of
  `*at` variants. There is no compatibility gap created by choosing
  ARM64.
- **Container image availability.** Most modern OSS container images publish
  multi-arch manifests (Go/Rust/Java/Python/Node base images, all major CNCF
  projects, Helm chart images, etc.). Multi-arch is the default for new images;
  the exceptions are increasingly small.
- **The exceptions.** Vendor-only x86 binaries (some commercial security tools,
  some legacy enterprise software), workloads using x86-specific instructions
  (AVX-512 in some HPC/ML kernels, Intel-specific crypto acceleration), and
  workloads not yet ported to ARM64 in the language itself (very narrow now —
  almost everything modern is multi-arch).
- **Operational consistency with the rest of the fleet.** The parent org is
  increasingly Graviton-first across non-secure node groups too. Making the
  secure module's default match the broader posture means workloads moving onto
  the secure node group don't change architecture at the same time as they
  change runtime, which keeps the "did Pod Identity break or did syscalls break
  or did ARM64 break" failure-mode triage cleanly separated.

This decision is about the _default value_ of `var.architecture` and the posture
for new workloads. The module continues to support `amd64` as a first-class
option; this is not a deprecation of x86_64 in the module.

## Decision

`var.architecture` defaults to `"arm64"`. New secure workloads target Graviton
unless there is a documented reason they cannot.

The module continues to accept `var.architecture = "amd64"` as a first-class
value. Mixed-architecture clusters instantiate the module twice — once for each
arch — using the standard `kubernetes.io/arch` label and a single shared
`workload-class=secure:NoSchedule` taint. Workloads opting into the secure node
group are expected to publish multi-arch images, or to document an x86
dependency and target the x86 node group explicitly.

The default instance-type sets are:

- `arm64` (default): `m7g.large`, `m7g.xlarge`, `m7g.2xlarge`, `c7g.large`,
  `c7g.xlarge`, `c7g.2xlarge`.
- `amd64`: `m7i.large`, `m7i.xlarge`, `m7i.2xlarge`, `c7i.large`, `c7i.xlarge`,
  `c7i.2xlarge`.

Burstable families (`t4g`, `t3`) are excluded from the defaults in either arch —
gVisor's syscall interception has measurable CPU overhead (5–15% per ADR-0005),
and burst credits would mask the steady-state cost and cause throttling under
load. Consumers can still override `var.instance_types` with burstable types for
dev environments where that tradeoff is acceptable.

Per ADR-0001, the actual instance-type list a consumer passes in production
lives in the Boilerplate-generated Terragrunt input object (`var.architecture`
as part of a larger architecture-shape input). The module-level defaults exist
for getting-started use and for tests; the fleet's real values are hoisted.

## Consequences

### Positive

- **Lower cost by default.** New secure workloads land on Graviton's better
  $/vCPU and $/RPS without anyone having to opt in. For the secure node group
  specifically — where gVisor's 5–15% CPU overhead is the cost of admission —
  recovering that overhead at the instance layer matters. Graviton roughly
  offsets gVisor's CPU tax on most workloads we expect to put here.
- **Better energy efficiency.** Graviton's perf/watt is materially better than
  current Intel/AMD parts at the same workload class. Not a primary driver, but
  aligns with the broader fleet direction.
- **Aligns the secure node group with the rest of the fleet's direction.** The
  non-secure node groups are already trending Graviton-first. Defaulting the
  secure module to the same arch keeps the platform's posture coherent —
  workloads don't switch arch _and_ runtime _and_ IAM posture in one move.
- **Pushes workloads toward multi-arch images.** Treating Graviton as the
  default exerts gentle pressure on internal tooling to publish multi-arch
  images, which is the right direction regardless. Workloads that hit an
  x86-only dependency surface it early, while there's still time to fix it,
  instead of after the fact.
- **gVisor parity is real.** The gVisor project has shipped `aarch64` `runsc`
  for years and treats it as a first-class architecture. There is no "Graviton
  is a second-tier gVisor target" risk to manage.

### Negative

- **Some commercial vendor binaries are x86-only.** Specific security tools,
  certain proprietary databases, and some legacy enterprise software still ship
  x86 binaries only. Workloads that depend on those must use
  `architecture = "amd64"` and accept the cost delta. Not a module-level problem
  to solve — caught at the workload-eligibility step.
- **x86-specific CPU features are not portable.** Workloads using AVX-512, Intel
  SGX, or other x86-specific instructions cannot move to ARM64. These are narrow
  but real. They land on the x86_64 instantiation of the module, not the
  Graviton default.
- **Cross-arch image builds become a workload prerequisite.** Workloads that
  don't already build multi-arch will need to add it (BuildKit
  `--platform=linux/arm64,linux/amd64`, GitHub Actions matrix, etc.). Mostly a
  one-time cost per workload, but a non-zero ask of teams onboarding to the
  secure node group.
- **Diagnosing arch-specific bugs requires arch-specific reproduction.** Stack
  traces, core dumps, and profiling data are arch-dependent. Teams unfamiliar
  with reading ARM64 disassembly may take longer to root-cause the rare
  ARM64-specific bug.

### Neutral

- **The module is _not_ arm64-only.** `amd64` remains a first-class value of
  `var.architecture` with its own AMI type, default instance set, and gVisor
  binary selection. Mixed-arch clusters are explicitly supported. This ADR sets
  the default; it does not deprecate x86_64.
- **Per-workload architecture choice is still per-workload.** The default steers
  new workloads; existing workloads with documented x86 dependencies are not in
  scope for migration by this ADR. Migration of existing x86-only workloads to
  ARM64 is a workload-level decision driven by the workload's owner, not the
  module's defaults.
- **Kubernetes scheduling does the right thing automatically.** Multi-arch
  container images and the `kubernetes.io/arch` label combine so the scheduler
  routes a pod to the architecture it has a layer for. No workload-author burden
  beyond publishing multi-arch images.
- **The default instance-type sets are starting points.** Production consumers
  hoist `var.architecture` and `var.instance_types` from Boilerplate-generated
  Terragrunt anyway (per ADR-0001). The module's defaults exist for
  getting-started and for tests, not as the fleet's prod values.

## Alternatives Considered

**Default `architecture = "amd64"`.** The historical safe default — every
container image runs on x86, every vendor binary is available, every team
already knows how to debug it. Rejected because:

- It pushes the cost overhead of gVisor (5–15%) onto more-expensive silicon by
  default. The combined cost on x86 + gVisor is materially higher than
  Graviton + gVisor for the same throughput on most workloads the secure node
  group is designed for.
- It contradicts the broader fleet direction. The non-secure node groups are
  trending Graviton-first; making the secure module default to x86 creates a
  fleet-inconsistency that has no operational justification.
- Multi-arch image support is mature in 2026. The "x86 is the only safe default"
  framing is outdated for new workloads.

**No default — require `architecture` to be set explicitly.** Force every
consumer to make the choice. Rejected: this is a getting-started ergonomic
regression with no upside. The right answer for >90% of new secure workloads is
Graviton; making consumers type it adds friction without buying any safety.
Consumers who _do_ want x86 still type it; consumers who want the recommended
default get it for free.

**Default to a multi-arch node group with mixed instance types.** Let one EKS
managed node group offer both `m7g` and `m7i` instance types and let the
scheduler sort it out via `kubernetes.io/arch`. Rejected because EKS managed
node groups require a single AMI type — they cannot host mixed-arch nodes. To
get mixed-arch, the module instantiates twice, once per arch. This is documented
in DESIGN-0001 and not a problem to solve at the module level.

**ARM64 + Bottlerocket instead of AL2023.** A separate future ADR may evaluate
Bottlerocket as a secure-workload AMI variant — it has a reduced attack surface
and supports gVisor. Out of scope for this decision, which is about CPU
architecture, not AMI. ADR-0008 covers the AMI-family decision and explicitly
defers Bottlerocket to a future variant module.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`
  (architecture-shape input is hoisted to Boilerplate-generated Terragrunt;
  module defaults are getting-started values).
- ADR-0002 — Node IAM minimization via Pod Identity (architecture-agnostic IAM
  posture).
- ADR-0005 — gVisor as the syscall sandboxing runtime (gVisor's `aarch64` binary
  support is what makes Graviton-default safe).
- ADR-0008 — AL2023 only (the AMI-family decision this architecture
  default composes with; Bottlerocket deferred to a future variant
  module).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where
  `var.architecture` lives and how it drives every arch-specific input;
  the per-arch instance-type defaults live in §"Architecture-driven
  inputs").
- AWS Graviton getting started:
  <https://github.com/aws/aws-graviton-getting-started>
- gVisor ARM64 syscall compatibility:
  <https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/>
- EKS AMI types (single AMI type per managed node group):
  <https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-amis.html>
