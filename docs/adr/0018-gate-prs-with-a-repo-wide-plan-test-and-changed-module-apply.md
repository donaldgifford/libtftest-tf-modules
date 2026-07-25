---
id: ADR-0018
title: "Gate PRs with a repo-wide plan test and changed-module apply tiers"
status: Accepted
author: Donald Gifford
created: 2026-07-25
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0018. Gate PRs with a repo-wide plan test and changed-module apply tiers

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [1. The three-tier per-module test taxonomy](#1-the-three-tier-per-module-test-taxonomy)
  - [2. The CI gating model](#2-the-ci-gating-model)
  - [3. Gate semantics: all present tiers must pass](#3-gate-semantics-all-present-tiers-must-pass)
  - [4. Coverage is visible in the README testing matrix](#4-coverage-is-visible-in-the-readme-testing-matrix)
  - [5. Fork PRs degrade gracefully](#5-fork-prs-degrade-gracefully)
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

This monorepo is a fleet of AWS Terraform modules validated with LocalStack.
RFC-0001 committed the fleet to a two-framework testing strategy, and two ADRs
record the framework-level split:

- **ADR-0013** — `terraform test` owns plan-time module invariants (resource
  shape, output contracts, IAM document structure, conditional gating,
  count/for_each expansion). Ships with the Terraform binary, no Go, runs in
  seconds.
- **ADR-0014** — libtftest owns apply-time runtime validation that needs more
  than the AWS API surface (EKS node readiness, addon DaemonSets, pod-identity
  credential flows).

Those ADRs answer *which framework tests what*. They do **not** answer *how CI
enforces testing across the fleet*. Two gaps remained:

1. **CI gated nothing.** Per INV-0006 (Finding F1), `ci.yml` was inherited
   Go-library boilerplate — a single miswired `labeler` job plus commented-out
   `go test` / `goreleaser` / `codecov` jobs. There was no Terraform validation,
   lint, plan-test, or LocalStack apply gating any PR on module correctness.
2. **The test surface had quietly grown a third tier.** Every module now ships a
   de-facto three-tier LocalStack layout (`tests/`, `tests-localstack/`, and —
   for Pro-only surfaces — `tests-localstack-pro/`), but that taxonomy and what
   CI should require of it were never recorded.

INV-0006 (resolved 1a/2c/3a/4a/5a/6a) decided the CI gating model now that
`LOCALSTACK_AUTH_TOKEN` is a repo secret; IMPL-0016 implements it. This ADR is
the **durable, referenceable record of the fleet testing strategy** those two
documents assume — the taxonomy, the gating scope, the gate semantics, and how
coverage is made visible — so contributors understand what is required of a
module's tests and why.

## Decision

### 1. The three-tier per-module test taxonomy

Every module is tested in up to three tiers, each a directory with a dedicated
`just` recipe. This layers concrete LocalStack tiers onto the ADR-0013/0014
framework split:

| Tier | Directory | Recipe | Needs | Applies to |
|------|-----------|--------|-------|------------|
| **Plan** | `tests/` | `just tf test <m>` | nothing (no AWS, no LocalStack) | **every** module (ADR-0013) |
| **Community apply** | `tests-localstack/` | `just tf test-localstack <m>` | LocalStack Community `:4566` | **every** module (plan-smoke where an upstream gap blocks apply) |
| **Pro apply** | `tests-localstack-pro/` | `just tf test-localstack-pro <m>` | LocalStack **Pro** + token | **only** modules with a Pro-gated surface (the RDS quartet today) |

The plan tier is the universal invariant gate. The apply tiers exercise the
module against an emulated AWS API. Which apply tiers a module ships is a
property of its **AWS surface** (a Pro-only resource ⇒ a Pro tier), not a per-PR
choice.

### 2. The CI gating model

- **Every PR runs a repo-wide plan test.** The plan tier (`just tf all` —
  validate + lint + fmt + plan-only `terraform test`) runs for **all** modules on
  every PR, with no LocalStack. It is cheap (~1s/module) and catches cross-module
  breakage that a diff-scoped run would miss. (INV-0006 Q1a)
- **Changed modules additionally run their apply tiers.** A module touched by the
  PR also runs its Community apply and — if it ships one — its Pro apply. The
  changed-module set is computed by an **in-repo change-detection recipe**
  (`scripts/changed-modules.sh` + a thin `just` wrapper — Q2a), not a third-party
  action, so the mapping is version-controlled, unit-testable, and runnable
  locally to preview what CI will do.
- **Cross-cutting changes fan out.** That recipe owns the fan-out rules (Q3a): a
  change to `justfile`, `mise.toml`, or `.github/**` re-runs **all** modules; a
  change to a shared fixture (`test/fixtures/reference-vpc`, …) re-runs that
  fixture's **consumers**.

### 3. Gate semantics: all present tiers must pass

For a changed module, the merge gate requires **every tier that module ships** to
be green. A module with all three tiers (plan + Community + Pro) must pass all
three; a module with two must pass both; a plan-only-relevant change must pass
the repo-wide plan. Because the per-module matrix is dynamic (branch protection
cannot enumerate per-module job names), enforcement is a **single aggregate
`ci-gate` job** that `needs:` all tier jobs and succeeds only when each
succeeded-or-legitimately-skipped. Branch protection requires that one check.
(INV-0006 Q5a)

### 4. Coverage is visible in the README testing matrix

`scripts/gen-readme.sh` renders the module × tier coverage matrix in `README.md`
(the `Plan tests | LocalStack | Pro` table plus the "Testing tiers" table), so
what each module is covered by — and therefore what the gate enforces for it — is
legible at a glance and regenerated when coverage changes. `just readme --check`
guards against drift in CI.

### 5. Fork PRs degrade gracefully

`LOCALSTACK_AUTH_TOKEN` is not exposed to `pull_request` runs from forks, so the
Pro tier cannot run there. Same-repo branches and push-to-`main` are fully
Pro-gated; fork PRs skip the Pro tier with a neutral/soft status rather than
hard-failing on the missing secret. This repo is internal-first, so fork PRs are
rare. (INV-0006 Q4a)

## Consequences

### Positive

- Fast universal feedback: the repo-wide plan tier gives every PR a sub-minute
  correctness signal with no infrastructure.
- Real apply coverage where it matters, at minimal CI cost — the expensive
  LocalStack tiers run only for the modules a PR actually touches.
- Legible, drift-guarded coverage: the README matrix shows exactly what the gate
  enforces per module.
- Local == CI: tools come from `mise.toml` via `jdx/mise-action` and CI runs the
  same `just tf` recipes a developer runs, so results are byte-identical.
- The gate cannot be bypassed by a green-but-empty run — the aggregate `ci-gate`
  job accounts for every tier.

### Negative

- The repo-wide plan matrix grows with the module count (still seconds per
  module, but not free).
- Apply tiers add minutes to a changed-module PR — the shared `reference-vpc`
  fixture's real NAT gateway alone is ~1–2 min per apply.
- The Pro tier cannot run on fork PRs; external contributions get reduced
  coverage until a maintainer re-runs.
- The change-detection + fan-out logic is bespoke and must be maintained and
  unit-tested as modules and shared fixtures evolve.

### Neutral

- Which apply tiers a module carries is determined by its AWS surface, not by the
  author — new modules inherit the taxonomy by convention.
- `terraform test` vs libtftest framework selection is unchanged; this ADR sits
  above that split (ADR-0013/0014) and governs CI enforcement, not framework
  choice.

## Alternatives Considered

- **Third-party change detection** (`dorny/paths-filter`, `tj-actions/changed-files`)
  — rejected in favor of an in-repo, locally-runnable, testable recipe; keeps the
  mapping version-controlled and shrinks the supply-chain surface. (INV-0006 Q2)
- **All tiers on every PR** — maximal safety but untenably slow: NAT-gateway +
  embedded-Postgres applies are minutes each, times every module, on every PR.
  (INV-0006 Q1c)
- **Plan-only gating, applies post-merge on `main`** — cheaper PRs, but apply
  regressions would land before detection. (INV-0006 Q1b)
- **Per-matrix-job required checks in branch protection** — impossible to
  enumerate reliably for a dynamic matrix; the aggregate `ci-gate` job replaces
  it. (INV-0006 Q5)
- **A standalone DESIGN doc for the strategy** — the framework rationale already
  lives in RFC-0001 / ADR-0013 / ADR-0014 and the implementation detail in
  IMPL-0016; a durable decision record (this ADR) is the right shape, not another
  design doc. (INV-0006 / IMPL-0016 Q6a)

## References

- RFC-0001 — the two-framework testing strategy this ADR operationalizes in CI.
- ADR-0013 — use `terraform test` for plan-time module invariants (the plan tier).
- ADR-0014 — use libtftest for apply-time runtime validation without AWS.
- ADR-0001 — cross-module composition via `terraform_remote_state` (the pattern
  the apply tiers' shared-fixture fan-out serves).
- INV-0006 — CI test gating on changed terraform modules with LocalStack (the
  decision record; resolved 1a/2c/3a/4a/5a/6a).
- IMPL-0016 — CI test-gating pipeline for changed Terraform modules (the
  implementation of this ADR).
- INV-0002 / INV-0003 — LocalStack-Pro auto-detection harness / CI-CD option
  survey (background).
- `scripts/gen-readme.sh` — renders the README testing coverage matrix.
- `README.md` "Testing tiers" — the developer-facing summary of the taxonomy.
