---
id: ADR-0013
title: "Use terraform test for plan-time module invariants"
status: Proposed
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0013. Use terraform test for plan-time module invariants

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [Scope: what terraform test owns](#scope-what-terraform-test-owns)
  - [Scope: what terraform test does not own](#scope-what-terraform-test-does-not-own)
  - [Conventions for new modules](#conventions-for-new-modules)
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
`terraform test` as the baseline, libtftest for the runtime track.
This ADR records the `terraform test` side of that split — when to
reach for it, what to use it for, and what its limits are.

The motivating facts:

1. **`terraform test` ships with the terraform binary**, requires no
   Go, runs in seconds, and expresses assertions in HCL `assert`
   blocks. The onboarding cost is approximately zero for anyone
   already writing Terraform.
2. **`terraform test` is not limited to mocked providers.** With the
   AWS provider's `endpoints` block or `AWS_ENDPOINT_URL`, a
   `run` block with `command = apply` will hit LocalStack just like
   libtftest does. The shared backend point matters because it
   collapses the "mocked vs real" distinction that an earlier framing
   leaned on.
3. **`override_data` and `override_resource` blocks stub specific
   data sources or resources surgically**, without mocking the whole
   provider. For modules that read upstream state via
   `data.terraform_remote_state` (this fleet's cross-module
   composition pattern per ADR-0001), `override_data` collapses the
   "seed a stub state file in LocalStack S3" libtftest pattern down
   to one HCL block.
4. **Plan-time invariants are the highest-leverage testing target for
   IaC modules.** Resource shape, output contracts, IAM policy
   document structure, conditional gating, count/for_each expansion,
   dependency ordering — these are the categories where regressions
   actually land, and they're all visible at plan time.
5. **The cluster module's Phase 8 (libtftest) is a working but
   overweighted reference**: ~250 lines of Go + LocalStack
   scaffolding to assert plan-time invariants that, in HCL, fit in
   a fraction of the space. The side-by-side `tests/*.tftest.hcl`
   suite for the same module is the proof point this ADR rests on.

The framing the team has converged on: there are real invariants
that need apply-time runtime validation (DaemonSet readiness, node
kubelet join, pod identity token exchange) — and there are real
invariants that don't. The first set is libtftest's job (ADR-0014).
The second set is `terraform test`'s job, by default, with no
ceremony.

## Decision

**Adopt `terraform test` as the default testing framework for every
module in this repo.** Every new module ships with a
`modules/<group>/<name>/tests/` directory containing one or more
`*.tftest.hcl` files exercising the module's plan-time invariants.

The runtime/apply track lives in libtftest (ADR-0014). The
delineation between the two is in RFC-0001 §Capability matrix and
§Migration trigger; this ADR records what `terraform test` is
expected to cover.

### Scope: what `terraform test` owns

Use `terraform test` for any of the following:

- **Plan-time resource shape assertions** — counts (`length(...)
  == N`), resource attributes (`aws_eks_cluster.this.access_config[0].authentication_mode == "API_AND_CONFIG_MAP"`),
  conditional gating (`length(aws_eks_access_entry.sso) == 0` when
  the SSO inputs are nil).
- **IAM policy document structure** — `jsondecode(aws_iam_role.foo.assume_role_policy)`
  against an expected statement shape. HCL handles JSON walking
  via `lookup`/`try` adequately for assertion-level checks.
- **Output contract assertions** — every module's outputs are part
  of the cross-module composition contract per ADR-0001. Asserting
  the output set + types prevents accidental breaking changes.
- **`override_data` for stubbed upstream state** — replace
  `data.terraform_remote_state.<x>` with literal values. Cleaner
  than seeding a LocalStack S3 object.
- **Single-module apply-time invariants on AWS-API-only modules**
  when LocalStack supports the surface. `command = apply` against
  LocalStack is valid `terraform test` usage and is appropriate for
  modules that don't need a K8s data plane.
- **CI gate for every PR.** Fast, deterministic, no container
  required (for plan-only runs). Should always pass before merge.

### Scope: what `terraform test` does *not* own

Reach for libtftest (ADR-0014) instead when the assertion requires
any of:

- **Kubernetes data plane state** — DaemonSet ready replicas, Pod
  scheduling, addon CRD installation. HCL has no path here; libtftest
  + kind/k3d does.
- **Multi-module apply chains** — apply cluster, capture state,
  apply node-group against it, capture state, apply addons. Each
  `terraform test` file is single-module; cross-module orchestration
  is libtftest's lane.
- **Pod identity token exchange / runtime IAM behavior** — needs
  LocalStack STS + a running pod-identity-agent in kind/k3d. Out of
  `terraform test`'s scope by construction.
- **sneakystack lifecycle management** — starting/stopping a proxy
  layer during a test run. `terraform test` can *consume* a
  sneakystack via env vars, but libtftest is the framework that
  owns the proxy's lifecycle.
- **Complex Go-side orchestration** — fixtures involving multiple
  AWS SDK calls, retries, polling, structured comparisons across
  many resources. HCL `assert` runs out of expressiveness; Go
  doesn't.

### Conventions for new modules

- Test files live in `modules/<group>/<name>/tests/*.tftest.hcl`.
- File naming reflects the scenario: `default.tftest.hcl`,
  `sso_enabled.tftest.hcl`, `kms_external.tftest.hcl`.
- Default to `command = plan` for invariants that don't require
  apply. Reach for `command = apply` only when apply-time behavior
  against LocalStack is the thing being asserted.
- Use `override_data` to stub `terraform_remote_state` data
  sources. Do not seed LocalStack S3 from `terraform test`;
  that pattern is libtftest's lane.
- Every module's README documents how to run its `terraform test`
  suite (one liner; should be `terraform test` from the module dir
  in the simple case).

## Consequences

### Positive

- **Fast CI feedback loop.** Plan-only `terraform test` runs in
  seconds. PR feedback cycles compress.
- **Low onboarding cost.** Anyone who can write Terraform can write
  tests. No Go, no harness API, no LocalStack container management
  for plan-only.
- **`override_data` collapses the cross-module-composition fixture
  cost.** Every consumer module in this fleet reads cluster + VPC
  remote state; with libtftest that's repeated LocalStack S3
  seeding, with `terraform test` it's repeated `override_data`
  blocks. The latter is dramatically less code.
- **Becomes the gap-discovery tool for the libtftest/sneakystack
  backlog.** Per RFC-0001 §`terraform test` as the gap-discovery
  tool: when a `command = apply` run fails because LocalStack
  returned 501, or when an invariant cannot be expressed in HCL
  `assert`, those failures are concrete, named tickets for
  Phase 3 work.
- **No fracture-by-default.** A module ships with one testing
  framework (`terraform test`). It only migrates to libtftest when
  the migration trigger from RFC-0001 fires — i.e., when a real
  invariant requires it.

### Negative

- **HCL `assert` is less expressive than Go for complex
  assertions.** Iterating over a list of resources to check a
  property on each, comparing structured outputs across many
  resources, regex over rendered userdata — HCL handles these but
  awkwardly. For the IAM policy docs in pod-identity-access
  (ALB controller has ~80 statements), this may surface as real
  friction. If it does, ADR-0013 gets scoped tighter rather than
  expanded.
- **No native LocalStack lifecycle.** `terraform test` does not
  start/stop a LocalStack container. Apply-time runs against
  LocalStack assume the container is already up (either
  developer-managed or via a CI fixture step). For plan-only runs
  this is a non-issue; for apply-time runs it's setup the
  developer carries.
- **Single-module scope.** Each `*.tftest.hcl` file targets one
  module's root configuration. Cross-module state apply chains
  cannot be expressed; the test file would have to be written as
  "this module + stubs for everything upstream," which `override_data`
  handles for read-only state but doesn't extend to "apply
  upstream first, then read its actual outputs."
- **Limits of `override_data`.** Stubbed values must be literal at
  declaration time. Dynamic stubbing (e.g., "this output depends
  on the test's run prefix") is awkward.

### Neutral

- **Apply-time `terraform test` against LocalStack is allowed and
  useful for AWS-API-only modules**, but it is not the dominant
  use case. Most modules in this fleet either don't need apply-time
  (cluster's IAM/KMS/SG/cluster resource set is mostly tested at
  plan) or need apply-time *with kind/k3d* (addons, node-group,
  pod-identity-access), which is libtftest's lane.
- **`terraform test` may evolve.** HashiCorp ships improvements
  release over release (better `override_*` ergonomics, richer
  assertion syntax). The ADR reviews if `terraform test`'s
  capability surface materially expands.
- **Cluster carries both frameworks deliberately.** Per RFC-0001
  §Where cluster sits, cluster is the side-by-side reference
  module. The cluster `tests/` suite under this ADR coexists with
  the cluster `test/` libtftest suite until cluster grows its
  first apply-time runtime invariant.

## Alternatives Considered

**Use libtftest for everything, including plan-time.** Rejected.
The cluster module's Phase 8 demonstrated the overhead: ~250 lines
of Go + LocalStack scaffolding for plan-only assertions that fit in
a fraction of the space in HCL. Compounds across every module in the
fleet. Blocks module work on libtftest harness completion. RFC-0001
walks through the full reasoning.

**Use `terraform test` for everything, including runtime
validation.** Rejected. Cannot express K8s data plane state,
multi-module apply chains, or pod identity token exchange. Pushes
those invariants to a sandbox AWS account at the Terragrunt-unit
level, which contradicts the "no AWS account required for module
CI" posture from RFC-0001.

**Use terratest for plan-time assertions.** Rejected. Same problem
as libtftest for plan-only — Go scaffolding cost compounded across
modules. Terratest's natural lane is real-AWS apply-time validation
in a sandbox account, which is out of scope here per RFC-0001.

**Use conftest / OPA for plan-time policy checks.** Considered, not
adopted (yet). Conftest is a real option for module-policy
assertions ("IAM policies must use `aws:SourceArn`," "every S3
bucket must have server-side encryption"). It complements
`terraform test` rather than replacing it: `terraform test`
asserts *this module's* behavior; conftest could enforce
*organization-wide* policies. Left as a possible later ADR if the
need arises; not the default testing framework today.

**Custom shell + jq harness.** Considered, rejected. Same end result
as `terraform test` (run plan, parse JSON, assert) with worse
ergonomics and no native HCL assertion language. `terraform test`
is the same idea done by HashiCorp.

## References

- [RFC-0001: Module Testing Strategy](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — the umbrella strategy this ADR implements.
- [ADR-0014: Use libtftest for apply-time runtime validation without AWS](0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — the complementary decision; reach for libtftest when this ADR's scope ends.
- [ADR-0001: Cross-module composition via `terraform_remote_state`](0001-cross-module-composition-via-terraformremotestate.md) — the composition pattern `override_data` stubs.
- [IMPL-0001: EKS Cluster Module Implementation](../impl/0001-eks-cluster-module-implementation.md) — Phase 8 (libtftest) is the comparison baseline; the cluster `tests/` suite is the proof point.
- [Terraform `test` command](https://developer.hashicorp.com/terraform/language/tests) — HashiCorp's documentation.
- [`override_data` block](https://developer.hashicorp.com/terraform/language/tests#override_data-blocks) — surgical data source stubbing.
