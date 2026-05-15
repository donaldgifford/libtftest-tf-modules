---
id: ADR-0014
title: "Use libtftest for apply-time runtime validation without AWS"
status: Proposed
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0014. Use libtftest for apply-time runtime validation without AWS

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [Scope: what libtftest owns](#scope-what-libtftest-owns)
  - [Scope: what libtftest does not own](#scope-what-libtftest-does-not-own)
  - [The harness shim: LocalStack + kind/k3d + sneakystack](#the-harness-shim-localstack--kindk3d--sneakystack)
  - [When a module migrates into libtftest](#when-a-module-migrates-into-libtftest)
- [Consequences](#consequences)
  - [Positive](#positive)
  - [Negative](#negative)
  - [Neutral](#neutral)
- [Alternatives Considered](#alternatives-considered)
- [References](#references)
<!--toc:end-->

## Status

Proposed

## Context

RFC-0001 commits the fleet to a two-framework testing strategy:
`terraform test` (ADR-0013) is the baseline for plan-time and
single-module apply-time invariants on AWS-API-only modules.
libtftest covers the rest — and "the rest" is specifically the
runtime track that needs more than the AWS API surface.

The motivating facts:

1. **Real EKS validation requires more than the AWS API.** A node
   group's value isn't "the AWS API recorded the registration" —
   it's "kubelet joined and the node is `Ready`." An addon's value
   isn't "the AWS API marked it ACTIVE" — it's "the DaemonSet is
   running on every node." A pod identity association's value
   isn't "the role is created" — it's "the pod can `AssumeRoleForPodIdentity`
   and the temporary credentials work." None of these are visible
   to `terraform test` because none of them are AWS-API-only.
2. **The org's testing posture forbids a sandbox AWS account in
   module CI.** Per RFC-0001 §Problem Statement, module-local
   testing has to run on a developer laptop and in CI without any
   AWS provisioning. That constraint rules out terratest-against-
   real-AWS for the module-local layer. (It does not rule it out
   for the Terragrunt-unit layer in infrastructure-live, where
   apply-against-sandbox-AWS lives.)
3. **LocalStack is necessary but not sufficient for EKS.**
   LocalStack Pro implements the EKS control-plane API surface
   (`aws_eks_cluster`, `aws_eks_node_group`, `aws_eks_addon`,
   `aws_eks_pod_identity_association`) well enough to plan and to
   record AWS API calls — but it does not run a real K8s data
   plane. Addon DaemonSets don't actually run. Kubelet doesn't
   actually join. Token exchange doesn't actually happen.
4. **kind/k3d provides the data plane LocalStack can't.** A local
   Kubernetes cluster (kind or k3d) provides the actual API server,
   scheduler, kubelet, and pod runtime. Pairing LocalStack (the AWS
   side) with kind/k3d (the K8s side) and bridging them — register
   LocalStack EKS cluster's endpoint at the kind/k3d API, mirror
   `aws_eks_addon` registrations to manifest applies in kind/k3d,
   route the pod-identity token exchange through LocalStack STS
   against kind/k3d service-account tokens — is the path to real
   runtime validation without AWS.
5. **sneakystack fills LocalStack's coverage gaps.** Some AWS API
   surfaces LocalStack doesn't implement at all, or implements with
   stub data that downstream module assertions can't use.
   sneakystack is the proxy that sits in front of LocalStack and
   serves those surfaces (either forwarded, faked, or enriched).
   Its lifecycle is libtftest's responsibility because it's part of
   the same test-time shim.
6. **libtftest exists to package this shim**. Per the libtftest
   project's goals: provide a Go-idiomatic harness for terraform
   apply-time tests against LocalStack + kind/k3d + sneakystack,
   with per-test parallel-safe prefixes, working-dir copies,
   service-specific assert packages (v0.3.0 plugin), and module
   hygiene primitives (`AssertIdempotent`,
   `tagsassert.PropagatesFromRoot`).

The framing: libtftest is the *only* path to module-CI runtime
validation of EKS-shaped modules without AWS. `terraform test`
cannot reach there by construction; terratest can but needs AWS.
That makes libtftest's scope narrow and specific — but in that
scope, indispensable.

## Decision

**Use libtftest for module tests whose assertions require apply-time
runtime behavior that LocalStack + kind/k3d + sneakystack can model,
and which `terraform test` cannot reach.** Module suites are written
in Go under `modules/<group>/<name>/test/` (singular, distinguishing
from `terraform test`'s `tests/` plural per ADR-0013).

The runtime track is libtftest. The migration trigger from RFC-0001
governs when a specific module crosses into it: capability gate (the
harness covers the case) AND value gate (a real invariant requires
apply-time).

### Scope: what libtftest owns

Use libtftest for any of the following:

- **Kubernetes data plane state assertions** — DaemonSet ready
  replicas after `aws_eks_addon` apply, node `Ready` status after
  node-group apply, Pod scheduling onto registered nodes.
- **Multi-module apply chains** — apply cluster module, capture
  its real LocalStack-backed state, use that state as the upstream
  for a node-group module apply, capture node-group state, apply
  addons against it, and so on. The end-to-end "the fleet stands
  up" story.
- **Pod identity token exchange validation** — a real service
  account in kind/k3d obtains a token, calls LocalStack STS via
  `AssumeRoleForPodIdentity`, and the returned credentials work
  against a (LocalStack-proxied or sneakystack-served) AWS API
  call. End-to-end.
- **Module hygiene primitives** — `AssertIdempotent` (apply twice,
  second is a no-op), `tagsassert.PropagatesFromRoot` (root tags
  reach every taggable resource), output-shape contracts that span
  many resources. These are expressible in `terraform test` only
  awkwardly; libtftest's v0.3.0 plugin gives them a clean home.
- **Side effects libtftest's harness manages** — sneakystack proxy
  startup/teardown, LocalStack edition selection
  (`localstack.EditionAuto` vs `EditionPro`), kind/k3d cluster
  lifecycle.
- **Complex Go-side test orchestration** — fixtures involving
  multiple AWS SDK calls, polling, retries, structured cross-resource
  comparisons. Where HCL `assert` runs out of expressiveness,
  libtftest's Go API takes over.

### Scope: what libtftest does *not* own

Push back to `terraform test` (ADR-0013) when:

- **The invariant is plan-time and AWS-API-shaped.** Don't reach
  for libtftest's harness for assertions that
  `terraform plan` already produces. The Phase 8 cluster suite
  showed the cost of doing this; the comparable `terraform test`
  suite is dramatically smaller. Stay on `terraform test` until
  the migration trigger fires.
- **The module has no K8s data plane / multi-module / token-exchange
  concern.** AWS-API-only modules (ecr-pull-through-cache, plain S3
  modules, plain IAM-role modules) belong on `terraform test`
  even when apply-time. libtftest's value comes from the shim
  components; if none of them are needed, libtftest is overkill.
- **The test would require a sandbox AWS account.** That's the
  Terragrunt-unit layer in infrastructure-live — terratest territory,
  not libtftest's. libtftest's reason to exist is removing the AWS
  account requirement.

### The harness shim: LocalStack + kind/k3d + sneakystack

libtftest's test environment composes three layers:

1. **LocalStack** — fakes the AWS API. EKS, IAM, KMS, EC2, STS,
   S3, etc. Pro for the EKS coverage; Community where it's enough.
2. **kind/k3d** — provides the actual Kubernetes API server, node,
   and pod runtime that LocalStack cannot. Used by tests that need
   to assert on DaemonSet readiness, Pod scheduling, or
   service-account token presentation.
3. **sneakystack** — proxies AWS API calls LocalStack doesn't
   serve, doesn't serve well, or returns stub data for. Filled in
   per gap as RFC-0001's gap-discovery loop surfaces them.

The harness is responsible for starting, connecting, and tearing
down all three. Tests should not need to know which layer answers
a given call — the harness exposes one AWS endpoint per test
(`tc.AWS()`) and one kubeconfig if K8s is requested.

This composition is what `terraform test` cannot do by itself:
not because `terraform test` can't *use* the shim (it can — point
the AWS provider at LocalStack via env vars), but because
`terraform test` doesn't *manage* the shim and doesn't reach into
the kind/k3d API for K8s-side assertions.

### When a module migrates into libtftest

Per RFC-0001 §Migration trigger, two gates must hold simultaneously:

1. **Capability gate**: the libtftest harness can apply-test the
   module against LocalStack + kind/k3d + sneakystack today.
2. **Value gate**: at least one invariant the module needs to
   validate is *not* catchable at `terraform test` time.

When both gates open, the module migrates: a Go test suite under
`modules/<group>/<name>/test/`, and the module's prior
`tests/*.tftest.hcl` (under ADR-0013) is retired. No module
carries both frameworks long-term *except cluster*, which is the
deliberate side-by-side reference per RFC-0001.

Conversely, if a module has invariants only apply-time can catch
but the harness can't cover them yet, the action is **file a Phase
3 harness or sneakystack ticket**, stay on `terraform test` in the
meantime, and document the gap. Do not migrate into a half-working
libtftest state.

## Consequences

### Positive

- **EKS runtime validation without AWS becomes possible.** This
  is the foundational outcome — node-group, addons, and
  pod-identity-access can be tested end-to-end on a developer
  laptop and in CI, without sandbox account provisioning. No other
  framework in scope achieves this for EKS-shaped modules.
- **Multi-module apply chains express the fleet's real shape.**
  Cluster's LocalStack-backed apply seeds node-group's, which seeds
  addons', which seeds pod-identity-access. The dependency chain
  Terragrunt expresses in production is testable end-to-end in
  libtftest.
- **Module hygiene primitives live in one place.** Idempotency,
  tag propagation, output contracts, plan-stability under re-apply
  — the v0.3.0 plugin's `AssertIdempotent` /
  `tagsassert.PropagatesFromRoot` / etc. cover patterns that
  generalize across modules. `terraform test` can express each
  individually but not as composable primitives.
- **The shim's investments compound.** Every sneakystack proxy
  added (gap from RFC-0001's discovery loop) benefits every later
  module that touches the same API. Every kind/k3d harness
  capability (addon manifest mirroring, token exchange path)
  unblocks not just one module but the class of modules that
  need it.

### Negative

- **Higher onboarding cost than `terraform test`.** Contributors
  need to know Go, the libtftest API, and (for runtime tests) the
  kind/k3d data plane. Plan-time tests in `terraform test` are
  approachable to a pure Terraform contributor; libtftest tests
  are not.
- **Slower CI than `terraform test`.** Container startup
  (LocalStack + kind/k3d + sneakystack) + per-test working-dir
  copies + `terraform init`/`apply` cycles add minutes to a run
  that `terraform test` plan-only completes in seconds. Worth
  the cost when the runtime invariants are real; not worth the
  cost when they aren't.
- **Harness fidelity is bounded.** LocalStack's EKS is not real
  EKS. kind/k3d's K8s is not the AWS-managed control plane. Some
  classes of bug (CNI behavior at scale, IAM policy evaluation
  edge cases, AWS-specific timing) won't reproduce in the shim.
  The real-AWS validation continues at the Terragrunt-unit layer.
- **Phase 3 harness engineering is on the critical path** for
  every EKS-runtime invariant. If kind/k3d bridge work stalls,
  module migrations stall. The mitigation (RFC-0001 §Phase 3) is
  treating harness work as its own track with tickets sourced from
  Phase 2's discovery loop.
- **Two test directories per migrated module-in-flight.**
  Specifically `test/` (libtftest, plural-less) and `tests/`
  (`terraform test`, plural). The naming is awkward but
  intentional — they signal which framework owns the directory
  without requiring tooling to disambiguate. Cluster carries both
  by design; no other module does long-term.

### Neutral

- **libtftest's v0.2.0 documents but does not implement
  `LIBTFTEST_CONTAINER_URL`.** The cluster module's Phase 8 worked
  around this in `TestMain`. The workaround is appropriate
  short-term; the proper fix is in libtftest itself and is a
  Phase 3 ticket.
- **libtftest is the user's own project.** This is both an
  alignment advantage (the ADR records using your own tool for the
  job it was built for) and a discipline point: changes to
  libtftest's API have to be coordinated with the modules that
  depend on it. The v0.3.0 plugin's assert-package design is
  appealing; the modules in this repo should consume it once it
  ships rather than churning against pre-release APIs.
- **Go skill is a contributor floor here.** That's the same
  floor libtftest's existence already assumes; this ADR doesn't
  raise or lower it.

## Alternatives Considered

**Use terratest for the runtime track.** Rejected. Terratest is
more mature and has the broader helper surface (ssh/k8s/retry/
http_helper), but it has no native LocalStack + kind/k3d + sneakystack
shim — every adopting repo rebuilds that integration itself.
libtftest's reason to exist is exactly to package that integration.
The right place for terratest is the consumer Terragrunt stack in
infrastructure-live, against a real sandbox AWS account; that's
out of scope here.

**Use `terraform test` for everything, including runtime.**
Rejected. K8s data plane state, multi-module apply chains, and
pod identity token exchange cannot be expressed. RFC-0001 and
ADR-0013 walk through the reasoning.

**Use real AWS sandbox account from module CI.** Rejected for
module-local tests. Account provisioning, IAM, blast radius, and
billing overhead are unjustifiable at the module layer. Appropriate
at the Terragrunt-unit layer in infrastructure-live.

**Defer runtime testing entirely until Terragrunt-unit layer.**
Rejected. Apply-time runtime regressions land in production. The
module layer needs to catch the K8s-shaped categories that
`terraform test` cannot, or the lowest layer that catches them is
infrastructure-live — which means the feedback loop is hours, not
seconds.

**Hand-rolled Go + LocalStack harness, not libtftest.** Rejected.
That's how libtftest started — extracting the pattern out of
hand-rolled harness code. Re-rolling it ad hoc here would
unmake the abstraction libtftest exists to provide. Investment in
libtftest itself (and sneakystack) compounds; ad-hoc harness
code doesn't.

## References

- [RFC-0001: Module Testing Strategy](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — the umbrella strategy this ADR implements.
- [ADR-0013: Use `terraform test` for plan-time module invariants](0013-use-terraform-test-for-plan-time-module-invariants.md) — the complementary decision; reach for `terraform test` when this ADR's scope ends.
- [ADR-0001: Cross-module composition via `terraform_remote_state`](0001-cross-module-composition-via-terraformremotestate.md) — the composition pattern libtftest's multi-module apply chains realize end-to-end.
- [ADR-0003: Pod Identity Agent installed on the addons module](0003-pod-identity-agent-installed-on-the-addons-module.md) — the agent-before-association invariant whose runtime form (DaemonSet ready before Pod tries to use the path) is libtftest-shaped.
- [IMPL-0001: EKS Cluster Module Implementation](../impl/0001-eks-cluster-module-implementation.md) — Phase 8's libtftest suite is the reference data point this ADR rests on.
- [libtftest](https://github.com/donaldgifford/libtftest) — the harness this ADR depends on.
- [sneakystack](https://github.com/donaldgifford/libtftest) — the proxy layer for LocalStack coverage gaps (lives alongside libtftest).
