---
id: INV-0006
title: "CI test gating on changed terraform modules with LocalStack"
status: Open
author: Donald Gifford
created: 2026-07-24
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0006: CI test gating on changed terraform modules with LocalStack

**Status:** Open
**Author:** Donald Gifford
**Date:** 2026-07-24

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Findings](#findings)
  - [F1 — What CI exists today (and what is dead)](#f1--what-ci-exists-today-and-what-is-dead)
  - [F2 — The test surface CI must drive](#f2--the-test-surface-ci-must-drive)
  - [F3 — Change detection maps cleanly to modules/service/name](#f3--change-detection-maps-cleanly-to-modulesservicename)
  - [F4 — The macOS named-volume gotcha is not a Linux-runner problem](#f4--the-macos-named-volume-gotcha-is-not-a-linux-runner-problem)
  - [F5 — The LocalStack Pro token unlocks the Pro apply tier in CI](#f5--the-localstack-pro-token-unlocks-the-pro-apply-tier-in-ci)
  - [F6 — Tool provisioning already solved by mise](#f6--tool-provisioning-already-solved-by-mise)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Open Questions](#open-questions)
  - [1. What is the required merge gate vs. best-effort?](#1-what-is-the-required-merge-gate-vs-best-effort)
  - [2. Change-detection mechanism?](#2-change-detection-mechanism)
  - [3. How do cross-cutting changes fan out?](#3-how-do-cross-cutting-changes-fan-out)
  - [4. LocalStack delivery in CI?](#4-localstack-delivery-in-ci)
  - [5. What happens to the inherited Go-library CI scaffolding?](#5-what-happens-to-the-inherited-go-library-ci-scaffolding)
  - [6. Do we keep the eks/cluster Go harness or converge on native tests?](#6-do-we-keep-the-ekscluster-go-harness-or-converge-on-native-tests)
- [References](#references)
<!--toc:end-->

## Question

`LOCALSTACK_AUTH_TOKEN` is now a repository Actions secret. **What should the CI
pipeline look like so that (a) every PR is gated on the Terraform modules'
tests passing, and (b) a CI run only exercises the module(s) actually changed in
that PR** — keeping the inherited-but-dead Go-library scaffolding out of the
way?

## Hypothesis

The current `ci.yml` is almost entirely commented-out Go-library boilerplate; the
only live job (`labeler`) is even miswired. The real gate is the existing `just
tf` recipes (`validate` / `lint` / `fmt` / `test` / `test-localstack` /
`test-localstack-pro`), which already encode everything a runner needs. A
`paths-filter` → matrix pattern over `modules/<service>/<name>/` plus
`jdx/mise-action` for pinned tools gives us per-changed-module gating with
minimal new machinery. The LocalStack "named-volume" gotcha is macOS-specific and
should not bite Linux runners.

## Context

CLAUDE.md's "CI caveat" already flags that `ci.yml` references a root `Makefile`
and Go code that do not exist. INV-0003 surveyed CI/CD *options* for the monorepo
(Concluded); INV-0002 designed a LocalStack-Pro *auto-detection* harness for
tests. This investigation is the concrete follow-up now that the Pro token exists
in CI: turn "options" into a gating pipeline scoped to changed modules.

**Triggered by:** `LOCALSTACK_AUTH_TOKEN` added to repo secrets; follow-up to
INV-0002 / INV-0003.

## Approach

1. Read every file in `.github/workflows/` + `.github/{dependabot,labeler}.yml`.
2. Separate live jobs from commented/`.bak` inherited scaffolding.
3. Map the local `just tf` recipes to CI steps.
4. Confirm the `modules/<service>/<name>/` layout supports path-filtered matrices.
5. Assess whether the macOS `initdb` named-volume gotcha applies on
   `ubuntu-latest`.

## Findings

### F1 — What CI exists today (and what is dead)

| Workflow | State | Notes |
|----------|-------|-------|
| `ci.yml` | **~dead** | Only a `labeler` job runs, and it is **miswired** — it lists `actions/labeler@v6` under a step named "Checkout code" with no `with:` config. Every real job (lint, test-go, test-integration, test-integration-pro, security, build) is **commented out** and is Go-library boilerplate (`make test-coverage`, `goreleaser`, `codecov`). |
| `pr-labels.yml` | live | Requires exactly one of `major/minor/patch/dont-release` (mheap/required-labels). This is the "patch label" gate. |
| `release.yml` | partial | `bump-version` (jefflinse/pr-semver-bump) tags from the merged PR's semver label; the `release`/`changelog-sync`/`docker` jobs are commented Go-library leftovers (references "sneakystack"). |
| `security.yml` | live | `govulncheck` on push + weekly cron → SARIF. **Go-only** — does not gate PRs and does not cover Terraform. |
| `changelog.yml.bak`, `license-check.yml.bak` | disabled | inherited. |
| `dependabot.yml` | live | github-actions (weekly), docker@`cicd` (daily), gomod@`/` (version updates off, security on). |

**Net:** there is **no Terraform validation, lint, plan-test, or LocalStack apply
in CI today, and nothing gates a PR on module correctness.** The commented
`test-integration-pro` block is the only place `LOCALSTACK_AUTH_TOKEN` was ever
referenced, and it runs `go test`, not `terraform test`.

### F2 — The test surface CI must drive

Every module already ships a three-tier local test layout, wrapped by `just tf`:

- `tests/` — plan-only `terraform test` (no LocalStack, ~1s). **The universal
  gate.** `just tf test <m>`.
- `tests-localstack/` — real Community apply. `just tf test-localstack <m>`.
- `tests-localstack-pro/` — Pro-only apply (RDS `proxy`/`cluster`/`instance`/
  `read-replica`). `just tf test-localstack-pro <m>`.

Only **one** module (`eks/cluster`) still carries a Go (libtftest) harness
(`modules/eks/cluster/test/go.mod`); every other module is native `terraform
test`. So the CI gate is **`terraform test`, not `go test`** — the inherited Go
jobs are the wrong tool. `just tf all <m>` already chains validate + lint + fmt +
plan-test.

### F3 — Change detection maps cleanly to modules/service/name

Modules live at a uniform `modules/<service>/<name>/` depth (e.g.
`modules/rds/serverless`, `modules/network/vpc-lookup`). A PR's changed paths map
1:1 to a module list via `dorny/paths-filter` or `tj-actions/changed-files`,
which then feeds a `strategy.matrix` so each changed module runs its own gate in
parallel. Cross-cutting changes (`test/fixtures/reference-vpc`, `justfile`,
`mise.toml`, `.github/`) should fan out to **all** dependent modules — the
shared-fixture consumers especially (a `reference-vpc` edit must re-run every RDS
apply suite).

### F4 — The macOS named-volume gotcha is not a Linux-runner problem

The RDS Pro applies fail on macOS because Docker Desktop's file-sharing ignores
in-container `chown`, so LocalStack's embedded-Postgres `initdb` sees a
root-owned data dir on the lstk **bind mount** (documented in the modules'
`FINDINGS.md`). On `ubuntu-latest`, Docker runs natively — bind-mount `chown`
sticks — so the workaround (a Docker **named volume**) is likely **unnecessary in
CI**. This should be confirmed with a single Pro-apply run on a runner, but it
means CI may be *simpler* than the local macOS path, not harder.

### F5 — The LocalStack Pro token unlocks the Pro apply tier in CI

With the token as a secret, CI can run a LocalStack **Pro** service container
(`localstack/localstack-pro`) and exercise `tests-localstack-pro`. Options: a
job-level `services:` container, or `localstack/setup-localstack` action. The
token is only needed on the Pro tier; the Community `tests-localstack` tier needs
no token. Secret exposure rules: **`LOCALSTACK_AUTH_TOKEN` is not available to
`pull_request` runs from forks** — for an internal-only repo this is a non-issue,
but it dictates whether the Pro tier can gate external PRs (it cannot) vs.
push-to-main / same-repo branches (it can).

### F6 — Tool provisioning already solved by mise

Every tool (terraform, tflint, terraform-docs, just, localstack/lstk, etc.) is
pinned in `mise.toml`. `jdx/mise-action` reproduces the exact local toolchain on
a runner in one step, so CI and local `just tf` stay byte-identical. No
per-tool `setup-*` actions needed.

## Conclusion

**Answer: The pipeline should be rebuilt around `terraform test` + `just tf`,
gated by a `paths-filter` → matrix over changed `modules/<service>/<name>/`, with
tools from `jdx/mise-action`.** Three gate tiers: (1) **always** — plan `just tf
all` per changed module (fast, required check); (2) **Community apply** — `just
tf test-localstack` per changed module against a LocalStack service container;
(3) **Pro apply** — `just tf test-localstack-pro` for the RDS quartet, using the
new token (likely no named-volume workaround on Linux). The inherited Go jobs and
`.bak` files should be deleted or clearly quarantined. INV-0003's option survey
is the backdrop; this makes it concrete and *gating*.

## Recommendation

Promote to a DESIGN + IMPL. Phase it: (1) replace `ci.yml`'s dead body with the
plan-tier gate (validate/lint/fmt/test over changed modules) as a required check;
(2) add the Community apply tier; (3) add the Pro apply tier behind the token,
confirming the Linux runner needs no named volume; (4) prune Go-library
scaffolding + `.bak`s; (5) decide the fan-out rules for shared-fixture / tooling
changes. Keep `pr-labels.yml` + `release.yml`'s `bump-version` as-is (orthogonal).

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
>
> **Resolved 2026-07-24 — 1a, 2c, 3a, 4a, 5a, 6a.** Plan tier required on every
> PR; the Community/Pro apply tiers are required but run only for changed
> modules (1a). **Change detection is an in-repo `just` recipe** that shells
> `git diff --name-only` into a module list (2c, *not* the third-party
> `paths-filter` action) — keeping the mapping version-controlled,
> unit-testable, and runnable locally to preview what CI will test. That same
> recipe owns the 3a fan-out rules (`test/fixtures/reference-vpc`, `justfile`,
> `mise.toml`, `.github/` → all dependent modules) and emits the matrix CI
> consumes. LocalStack is delivered as a `services:` container per apply job
> (4a). The commented Go-library jobs + `.bak` files are deleted, keeping
> `security.yml`/`govulncheck` scoped to the remaining Go dirs (5a). The
> `eks/cluster` Go-harness keep-vs-retire question is out of scope here —
> noted for a follow-up (6a), and it interacts with INV-0007's `x/crypto`
> alerts.

### 1. What is the *required* merge gate vs. best-effort?

- **a — Plan tier required; apply tiers required-but-only-for-changed-modules.**
  *(recommended)* `just tf all` (plan) blocks every PR; Community/Pro applies
  block only when their module changed. Fast feedback, real coverage where it
  matters.
- **b — Only the plan tier gates; applies run post-merge on `main`.** Cheaper PRs,
  but apply regressions land before they're caught.
- **c — All tiers required on every PR.** Maximal safety, slowest (NAT + embedded
  Postgres make applies minutes-long).
- **other.**

### 2. Change-detection mechanism?

- **a — `dorny/paths-filter` → `strategy.matrix`.** *(recommended)* Mature,
  outputs a per-module boolean/list, easy matrix fan-out.
- **b — `tj-actions/changed-files`.** Richer globbing; heavier, and has had
  supply-chain advisories worth pinning-by-SHA.
- **c — A `just` recipe that shells `git diff --name-only` into a module list.**
  Keeps logic in-repo/testable; more bespoke.
- **other.**

### 3. How do cross-cutting changes fan out?

- **a — A change to `test/fixtures/reference-vpc`, `justfile`, `mise.toml`, or
  `.github/` fans out to all (or all dependent) modules.** *(recommended)* The
  shared fixture's consumers must re-run; safest.
- **b — Only run directly-changed module paths; accept that shared-fixture edits
  are covered by a nightly full run.** Faster PRs, delayed detection.
- **other.**

### 4. LocalStack delivery in CI?

- **a — `services:` container per apply job** (`localstack/localstack` Community
  tier; `localstack/localstack-pro` for the Pro job with the token). *(recommended)*
  Native GH Actions primitive, health-checkable.
- **b — `localstack/setup-localstack` action.** Higher-level, opinionated;
  another action to pin/trust.
- **other.**

### 5. What happens to the inherited Go-library CI scaffolding?

- **a — Delete the commented jobs + `.bak` files; keep `security.yml`
  (govulncheck) scoped to the Go dirs that remain.** *(recommended)* Once
  `tools/bedrock-keyctl` leaves (see INV-0007), the only Go left is
  `modules/eks/cluster/test`.
- **b — Leave them commented as a template.** Zero risk, ongoing confusion.
- **other.**

### 6. Do we keep the `eks/cluster` Go harness or converge on native tests?

- **a — Out of scope here; note it and open a follow-up.** *(recommended)* The
  Go vs. native-test convergence is its own decision (and interacts with the 13
  `x/crypto` alerts in that harness — INV-0007).
- **b — Fold it into this CI work: gate the Go harness with `go test` in the
  same matrix.** Couples two concerns.
- **other.**

## References

- INV-0003 — CI/CD options for a Terraform-modules monorepo (the option survey
  this makes concrete).
- INV-0002 — fleet-wide LocalStack-Pro auto-detection harness for tests.
- INV-0007 — open Renovate/Dependabot PRs + security triage (the `x/crypto`
  alerts live in the one Go harness CI would run).
- `.github/workflows/ci.yml` — the mostly-dead current pipeline.
- `justfile` — the `just tf {validate,lint,fmt,test,test-localstack,test-localstack-pro}`
  recipes CI should wrap.
- `project-localstack-rds-needs-named-volume` (memory) — the macOS-only gotcha.
