---
id: ADR-0005
title: "gVisor as the syscall sandboxing runtime"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0005. gVisor as the syscall sandboxing runtime

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

The secure managed-node-group module (DESIGN-0001) exists to host workloads
that need defense-in-depth at the syscall layer — multi-tenant code,
untrusted third-party code, internal-build runners, anything where the
standard container boundary (namespaces + cgroups + seccomp + AppArmor) is
not by itself the level of isolation we want.

The question this ADR settles is *which* sandboxing technology that module
ships with. The candidates that AWS EC2 + EKS managed node groups can run
today are:

1. **gVisor (`runsc`)** — userspace re-implementation of the Linux syscall
   interface. Application syscalls are intercepted (via `seccomp` + signals
   on the `systrap` platform) and serviced by the gVisor sentry instead of
   the host kernel. The host kernel only sees a small set of syscalls from
   the sentry itself.
2. **Kata Containers** — each pod runs in a lightweight VM (QEMU /
   Firecracker / Cloud Hypervisor backing). Strong isolation via a hardware
   virtualization boundary; requires nested virtualization or bare metal.
3. **Firecracker (direct)** — AWS's microVM monitor, the same one that
   powers Lambda and Fargate internals. Not a container drop-in by itself;
   would require us to build or adopt a Kata-like wrapper.
4. **seccomp-only (no sandbox runtime)** — stay on the default `runc` and
   rely on tight seccomp profiles + AppArmor + readOnlyRootFilesystem +
   dropped capabilities. Industry baseline; not a sandbox in the same class
   as the above.

The module's syscall compatibility analysis was carried out against the
gVisor option specifically (the upstream gVisor compatibility tables —
links in References), because that is the option the module's
`user_data.sh.tftpl` installs. This ADR captures *why* gVisor is
the option the module installs — i.e., why we evaluated against gVisor's
syscall table rather than Kata's hypervisor boundary or Firecracker's
microVM model.

The runtime is integrated via the `runsc` containerd shim and surfaced to
Kubernetes through a `RuntimeClass` named `gvisor` (handler `runsc`).
Workloads opt in via `spec.runtimeClassName: gvisor` plus the
`workload-class=secure` toleration. Workloads that don't opt in continue to
run on `runc` on other node groups, untouched.

## Decision

The secure managed-node-group module uses **gVisor (`runsc`)** as its
sandboxing runtime, installed via the official gVisor release binaries
(`runsc` + `containerd-shim-runsc-v1`) into `/usr/local/bin/` from the EKS
node's user data. The runtime is configured with:

- **Platform: `systrap`** — uses `seccomp` + signals to intercept syscalls.
  Works on Nitro EC2 instances without nested virtualization, supports both
  ARM64 and x86_64. `kvm` (faster, but requires nested virtualization not
  available on most EC2 types) and `ptrace` (legacy fallback) are not used.
- **Network: `sandbox`** — gVisor's userspace `netstack` TCP/IP. The
  container's network stack does not share state with the host kernel.
  `network = "host"` is not used, because it negates much of the isolation
  value of running gVisor in the first place.

The runtime is registered with containerd via a drop-in at
`/etc/containerd/config.d/runsc.toml` (AL2023's nodeadm-managed
`/etc/containerd/config.toml` is left alone), and surfaced to Kubernetes
through a single cluster-scoped `RuntimeClass` named `gvisor`.

Workload eligibility is determined per-workload using the evaluation
procedure formalized in DESIGN-0001 §"Workload compatibility evaluation
procedure" — static
runtime/language check, runtime test on a dev gVisor node, `strace -c`
compatibility sweep, and a captured result in the workload's repo.
Workloads that fail eligibility do not opt into the secure node group; they
stay on standard node groups under `runc`.

## Consequences

### Positive

- **Defense-in-depth at the syscall layer.** The host kernel sees a small,
  audited set of syscalls from the gVisor sentry rather than the full
  syscall surface of the workload. A kernel-level exploit in the workload's
  syscalls has the sentry between it and the host. This is the property the
  module exists to provide; nothing else on this list matters if this one
  isn't true.
- **Composes with the rest of the security posture.** gVisor stacks
  on top of, and does not replace, the existing controls: minimal node IAM
  (ADR-0002), IMDSv2 + hop-limit 2, KMS-encrypted EBS, dropped
  capabilities, seccomp, AppArmor, readOnlyRootFilesystem, Pod Identity for
  workload AWS credentials. gVisor is one layer of many, not a substitute
  for any of them.
- **Runs on standard EC2 Nitro instances.** No nested virtualization, no
  bare-metal instance families, no Firecracker-specific AMI work. The same
  `m7g`/`c7g`/`r7g` (Graviton) and `m6i`/`c7i`/`r7i` (Intel/AMD) families
  the rest of the fleet uses are valid hosts. Capacity decisions don't
  branch on "is this a secure workload" — the instance market is the same.
- **AL2023 + containerd 1.7+ supported out of the box.** The official
  gVisor releases ship a containerd shim that AL2023's containerd builds
  load via a drop-in. No custom AMI, no kernel patches, no AWS-side
  enablement.
- **ARM64 and x86_64 covered.** gVisor publishes both `aarch64` and
  `x86_64` `runsc` binaries from the same release. The module's
  architecture-pinned design (DESIGN-0001) drops in cleanly — one node
  group per arch, same runtime, same RuntimeClass.
- **Per-workload opt-in via RuntimeClass is clean.** Workloads choose
  gVisor by setting `spec.runtimeClassName: gvisor`. Workloads that don't
  opt in run on `runc` on standard node groups, with no visible difference.
  The taint (`workload-class=secure:NoSchedule`) prevents accidental
  landing of non-opt-in workloads.
- **Reversible at the workload level.** If a specific workload is found to
  be incompatible (heavy `io_uring`-targeting databases, BPF-loading-
  inside-the-sandbox observability tools — see the upstream gVisor
  compatibility tables in References), removing
  `runtimeClassName: gvisor` from that workload's pod spec returns it
  to `runc`. The runtime decision is
  per-workload, not per-cluster or per-node group.

### Negative

- **Performance overhead, particularly on syscall-heavy workloads.**
  Syscall interception adds latency. Typical web/RPC services see 5-15% CPU
  overhead. I/O-heavy workloads using Linux native AIO see partial-support
  performance regression; workloads targeting `io_uring` see significant
  regression. The upstream gVisor compatibility tables (linked in
  References) capture the per-workload-class numbers. This is the cost
  of the sentry boundary —
  unavoidable for the class of isolation gVisor provides.
- **Real syscall compatibility gaps.** Specific workload patterns are
  incompatible:
  - **Loading BPF programs inside the sandbox** — `bpf(2)` is `EPERM` for
    non-root, `ENOSYS` for root. Affects modern observability agents that
    self-instrument, Cilium-internal data planes, in-pod tracers. Host-side
    eBPF (Falco, Tetragon, Cilium agent on the node) is unaffected.
  - **NUMA-tuned workloads** — gVisor advertises a single NUMA node.
    NUMA-pinned databases (Redis, Cassandra, large JVMs) lose tuning
    effectiveness.
  - **Real-time scheduling (`SCHED_FIFO`/`SCHED_RR`)** — gVisor doesn't
    implement a Linux-compatible scheduler. Affects game servers,
    real-time audio, latency-sensitive HFT-style workloads.
  - **`io_uring`-targeting databases** — ScyllaDB, modern PostgreSQL
    builds, `tokio-uring`-based Rust services. Falls back or fails.
  - **`mlock` for cryptographic secrets** — the call succeeds but pages
    aren't actually pinned. Functionally OK on cloud VMs that don't swap,
    but the workload should know that the protection isn't real.

  The evaluation procedure exists to catch these before a workload is
  declared eligible. They are real but bounded.
- **`hostNetwork: true` is mutually exclusive with sandboxing.** Workloads
  that need direct host network access (some service-mesh data planes,
  legacy Prometheus exporters that scrape the node) cannot run under
  gVisor. They stay on standard node groups under `runc`. Documented in
  DESIGN-0001's Non-Goals.
- **A new failure mode to operate.** Syscall fallbacks manifest as
  `ENOSYS` / `EPERM` in workload logs — easy to misdiagnose as workload
  bugs the first time the team sees one. The post-deploy validation
  checks in DESIGN-0001 §"Integration validation" and the runtime-test
  step of the evaluation procedure exist to surface these during
  eligibility, not in prod.
- **gVisor release cadence is the project's, not AWS's.** AWS does not
  publish a managed gVisor — version bumps are our responsibility, driven
  by Renovate against the gVisor release URL. Compared to managed addons
  whose lifecycle is on the EKS side, gVisor is a userland binary we pin.

### Neutral

- **gVisor's threat model is "sandbox the workload from the host kernel,"
  not "sandbox the workload from a VM-level adversary."** It's not a VM and
  does not claim to be one. For threat models that genuinely require
  hardware-virtualization isolation, gVisor is the wrong tool — Kata is.
  For our current secure-workload class (internal-build runners,
  multi-tenant code paths, untrusted third-party code at the application
  layer), the syscall boundary is the boundary that matters. This may
  change for some future workload class; if it does, the answer is a
  *different* node group module, not a different runtime in this one.
- **Per-workload compatibility evaluation is now part of the workload
  onboarding flow.** Workloads going onto the secure node group go through
  the evaluation procedure once. The result lives in the workload's repo,
  not in this module. Documented and accepted.
- **The `runsc` binary lives in `/usr/local/bin/`, not in a managed AMI
  layer.** Re-installs on every new node via user data. Adds ~30s to first
  boot. Acceptable; the alternative (custom AMI build pipeline) introduces
  a larger ops surface.

## Alternatives Considered

**Kata Containers.** Per-pod lightweight VM with a hardware-virtualization
boundary. Stronger isolation than gVisor in the threat-model sense — a
syscall-level escape in the sandbox doesn't reach the host kernel, it
reaches the hypervisor. Rejected for this module because:

- Requires nested virtualization or bare-metal instance families. Nested
  virt is not available on most EC2 instance types (and not available on
  Graviton at all in the way Kata needs); bare-metal types
  (`m5.metal`/`c7g.metal`/etc.) carve out the instance market severely and
  cost-scale poorly per pod compared to non-metal Graviton.
- Bigger per-pod boot and memory cost. Each pod pays the VM startup tax;
  memory ballooning helps but the floor is higher than a userspace sentry.
- Heavier ops surface. Kata's hypervisor backends (Firecracker, QEMU,
  Cloud Hypervisor), guest kernel pinning, and shared filesystem semantics
  (`virtio-fs`) add components to operate. Our team is one person.
- The threat model the secure node group exists for — defense-in-depth at
  the syscall layer for application-class workloads — is well-served by
  gVisor's boundary. A VM boundary is the right tool for a different
  threat model (e.g., hostile-tenant code that we cannot trust at the
  syscall layer at all), which is not the current class.

If a future workload class genuinely needs hardware-virtualization
isolation, the answer is a separate Kata-on-bare-metal node group module,
not a runtime swap inside this one.

**Firecracker directly.** AWS's microVM monitor — the engine inside Lambda
and Fargate. Rejected because it is not a container drop-in. To run
Kubernetes pods on Firecracker we would adopt Kata-with-Firecracker-backend
(see above) or build a custom integration. Both reduce to "Kata, but
specifically the Firecracker variant," which doesn't change the
Kata-vs-gVisor conclusion. Standalone Firecracker (without a Kata-like
shim) is the wrong abstraction layer for a Kubernetes workload runtime.

**seccomp-only (default `runc` with tight profiles).** Stay on `runc`,
ship a strict seccomp profile per workload, layer AppArmor, drop
capabilities, readOnlyRootFilesystem, etc. Rejected as a *substitute* for
gVisor — these are different layers of defense. seccomp blocks specific
syscalls from being made at all; gVisor intercepts syscalls and services
them in userspace so the host kernel never executes them on the workload's
behalf. seccomp gives the workload "you can call these syscalls and only
these"; gVisor gives the workload "you can call whatever, but a userspace
sentry decides what to do with it." The two compose — gVisor-sandboxed
pods still benefit from tight seccomp profiles, AppArmor, and minimal caps.
We keep all of those; gVisor is the additional layer the secure node group
adds, not a replacement.

**Self-managed kernel sandboxing (custom seccomp + namespace work, no
external runtime).** Rejected: would re-implement a substantial fraction of
what gVisor already does, at much lower assurance. The gVisor sentry has
years of fuzzing, threat-modeling, and production exposure inside Google.
We are not going to do better in-house.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- ADR-0002 — Node IAM minimization via Pod Identity (the syscall sandbox
  composes with, and does not replace, the node-identity posture).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where this
  runtime is installed, configured, and gated to opt-in workloads).
- gVisor official documentation: <https://gvisor.dev/docs/>
- gVisor production guide: <https://gvisor.dev/docs/user_guide/production/>
- gVisor + containerd quick start:
  <https://gvisor.dev/docs/user_guide/containerd/quick_start/>
- gVisor ARM64 syscall compatibility:
  <https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/>
- gVisor x86_64 syscall compatibility:
  <https://gvisor.dev/docs/user_guide/compatibility/linux/amd64/>
- Kubernetes RuntimeClass:
  <https://kubernetes.io/docs/concepts/containers/runtime-class/>
- Kata Containers (for comparison only):
  <https://katacontainers.io/>
