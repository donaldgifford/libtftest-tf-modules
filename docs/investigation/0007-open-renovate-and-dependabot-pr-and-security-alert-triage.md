---
id: INV-0007
title: "Open Renovate and Dependabot PR and security-alert triage"
status: Open
author: Donald Gifford
created: 2026-07-24
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0007: Open Renovate and Dependabot PR and security-alert triage

**Status:** Open
**Author:** Donald Gifford
**Date:** 2026-07-24

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Findings](#findings)
  - [F1 — All 13 security alerts are one dependency in one file](#f1--all-13-security-alerts-are-one-dependency-in-one-file)
  - [F2 — Dependabot PR #35 closes all 13](#f2--dependabot-pr-35-closes-all-13)
  - [F3 — Nothing to ignore: zero bedrock-keyctl alerts](#f3--nothing-to-ignore-zero-bedrock-keyctl-alerts)
  - [F4 — The other open PRs are routine version bumps](#f4--the-other-open-prs-are-routine-version-bumps)
  - [F5 — dependabot.yml does not scan the nested go.mods for version updates](#f5--dependabotyml-does-not-scan-the-nested-gomods-for-version-updates)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Open Questions](#open-questions)
  - [1. How do we land the security fix?](#1-how-do-we-land-the-security-fix)
  - [2. What do we do about the source of the alerts long-term?](#2-what-do-we-do-about-the-source-of-the-alerts-long-term)
  - [3. Renovate/Dependabot version-PR batch policy?](#3-renovatedependabot-version-pr-batch-policy)
  - [4. Fix the dependabot.yml gomod directory gap?](#4-fix-the-dependabotyml-gomod-directory-gap)
- [References](#references)
<!--toc:end-->

## Question

There are **13 open Dependabot security alerts (7 critical, 2 high, 4 moderate)**
plus a stack of open Renovate and Dependabot version PRs. **Which open PR(s)
actually fix the security alerts, which are routine maintenance, and — excluding
anything in `tools/bedrock-keyctl` (which is leaving the repo) — what is the
recommended merge order?**

## Hypothesis

The alert count (13) is inflated by multiple advisories against a *single*
dependency version; one bump likely clears all of them. The Renovate PRs are
tooling-pin updates (mise datasources) with no security weight. If any alerts sit
in `tools/bedrock-keyctl`, they are out of scope per the planned extraction.

## Context

The push that opened PR #57 surfaced a GitHub banner: "13 vulnerabilities on the
default branch (7 critical, 2 high, 4 moderate)". `tools/bedrock-keyctl` is
slated to move to its own repository, so its dependency hygiene should not gate
work here.

**Triggered by:** the Dependabot banner on push; user request to triage.

## Approach

1. `gh api …/dependabot/alerts?state=open` — enumerate + group by manifest.
2. `gh pr list` — enumerate open Renovate + Dependabot PRs.
3. Cross-reference: which PR's diff matches the alerted dependency/version.
4. Read `.github/dependabot.yml` for why nested go.mods aren't version-scanned.

## Findings

### F1 — All 13 security alerts are one dependency in one file

Grouped by manifest, **every** open alert is the same package/version:

| Count | Severity | Package | Manifest | Vulnerable → Patched |
|-------|----------|---------|----------|----------------------|
| 7 | CRITICAL | `golang.org/x/crypto` | `modules/eks/cluster/test/go.mod` | `< 0.52.0` → `0.52.0` |
| 2 | HIGH | `golang.org/x/crypto` | same | `< 0.52.0` → `0.52.0` |
| 4 | MEDIUM | `golang.org/x/crypto` | same | `< 0.52.0` → `0.52.0` |

The "13 vulnerabilities" is **13 advisories against one pinned version** of
`golang.org/x/crypto` in the **one remaining Go test harness**
(`modules/eks/cluster/test` — the only non-tool `go.mod` in the repo). It is
*test* code (libtftest/Terratest), not module-runtime or shipped code.

### F2 — Dependabot PR #35 closes all 13

`gh pr view 35`: **"bump golang.org/x/crypto from 0.49.0 to 0.52.0 in
/modules/eks/cluster/test"**, touching exactly the `go.mod` and `go.sum` under
`modules/eks/cluster/test`. `0.52.0` is the first-patched version for all 13
advisories, so **PR #35 alone resolves the entire banner.** It is a Dependabot
*security* update (the only security-bearing PR in the open set).

### F3 — Nothing to ignore: zero bedrock-keyctl alerts

The user asked to skip anything under `tools/bedrock-keyctl` (planned extraction
to its own repo). **No open alert is in `tools/bedrock-keyctl`** — its earlier
call-reachable Go-stdlib CVEs were already cleared by the `mise.toml` Go bump to
1.26.4 (CLAUDE.md). So the exclusion is moot for *this* triage: merging #35
clears 100% of the open alerts.

### F4 — The other open PRs are routine version bumps

| # | Bot | Change | Security? |
|---|-----|--------|-----------|
| 35 | dependabot | `golang.org/x/crypto` 0.49.0 → **0.52.0** (eks/cluster test) | **YES — fixes all 13** |
| 55 | dependabot | `actions/checkout` 6 → 7.0.0 | no |
| 54 | dependabot | `github/codeql-action` 4 → 4.37.0 | no |
| 53 | dependabot | `actions/labeler` 6 → 6.2.0 | no |
| 30 | dependabot | `mheap/github-action-required-labels` 5 → 5.5.2 | no |
| 50 | renovate | `terraform-linters/tflint` → 0.64.0 | no |
| 49 | renovate | `prettier` → 3.9.6 | no |
| 48 | renovate | `mikefarah/yq` → 4.53.3 | no |
| 47 | renovate | `localstack/lstk` → 0.18.0 | no |
| 46 | renovate | `hashicorp/terraform` → 1.15.8 | no |
| 45 | renovate | `google/yamlfmt` → 0.21.0 | no |
| 44 | renovate | `golangci/golangci-lint` → 2.12.2 | no |
| 43 | renovate | `adrienverge/yamllint` → 1.38.0 | no |
| 41 | renovate | `gruntwork-io/terragrunt` → 0.99.5 | no |
| 40 | renovate | `golang/go` → 1.26.5 | no* |
| 7 | guardian | `[GUARDIAN] add-missing-files` | n/a (repo hygiene) |

`*` #40 bumps the **Go toolchain** (stdlib), which patches stdlib CVEs but does
**not** touch the `golang.org/x/crypto` *module* — it does not close any of the
13. (Still worth taking for the stdlib posture the bedrock-keyctl work
established.) Renovate #47 (`lstk` 0.18.0) and #46 (`terraform` 1.15.8) are the
tooling the CI work in INV-0006 will lean on.

### F5 — dependabot.yml does not scan the nested go.mods for version updates

`.github/dependabot.yml` declares `gomod` only at `directory: "/"` with
`open-pull-requests-limit: 0` (version updates disabled). There is no `go.mod` at
`/` — the real ones are `modules/eks/cluster/test` and `tools/bedrock-keyctl`. So
**version** updates never scan them; only **security** updates do (that is how
PR #35 appeared, repo-wide by dependency graph). If we want proactive version
updates for the nested Go module(s) that remain, `dependabot.yml` needs explicit
`directory` entries (or `directories: ["**"]`) — but if `bedrock-keyctl` leaves
and the `eks/cluster` Go harness is retired (INV-0006 Q6), there may be no Go
module left to track.

## Conclusion

**Answer: merge Dependabot #35 — it resolves all 13 alerts (7 critical / 2 high /
4 moderate) in one bump of a single test-only dependency; nothing is in
`bedrock-keyctl`, so nothing is deferred.** Every other open PR is routine
tooling maintenance with no security weight (#40's Go bump improves stdlib
posture but does not close any alert).

## Recommendation

1. **Merge #35 immediately** (patch label) → clears the banner.
2. Batch-merge the Renovate tooling PRs, prioritizing the ones INV-0006 needs
   (#47 lstk, #46 terraform, #44 golangci-lint, #50 tflint) — ideally *after* a
   test-gating CI exists so they self-verify.
3. Take the GitHub-Actions bumps (#55/#54/#53/#30) as part of the CI rebuild
   (INV-0006), where those actions are actually used.
4. Decide `dependabot.yml` nested-go.mod coverage **after** the
   bedrock-keyctl extraction + the eks/cluster Go-harness keep/retire call.
5. Triage the guardian PR (#7) separately — it is repo-scaffolding, not deps.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.

### 1. How do we land the security fix?

- **a — Merge #35 now, standalone, with a `patch` label.** *(recommended)*
  Smallest possible change that clears all 13 alerts; test-only dependency.
- **b — Wait until the test-gating CI (INV-0006) exists so #35 self-verifies.**
  Safer signal, but leaves criticals open in the meantime.
- **other.**

### 2. What do we do about the source of the alerts long-term?

- **a — Keep the `eks/cluster` Go harness for now; #35 keeps it patched.**
  *(recommended)* Defer the keep/retire decision to INV-0006 Q6.
- **b — Retire the `eks/cluster` Go harness (converge on native `terraform
  test`), which deletes the only alerted `go.mod` outright.** Bigger change;
  removes the whole class of Go-test-dep alerts.
- **other.**

### 3. Renovate/Dependabot version-PR batch policy?

- **a — Hold the non-security bumps until CI gates them, then batch-merge.**
  *(recommended)* Avoids blind merges; CI proves each bump.
- **b — Merge low-risk tooling bumps now** (they only touch `mise.toml` /
  workflow pins). Faster, but unverified until CI exists.
- **other.**

### 4. Fix the `dependabot.yml` gomod directory gap?

- **a — Defer** until after bedrock-keyctl extraction + the Go-harness decision.
  *(recommended)* The set of tracked go.mods is about to change.
- **b — Add `directories: ["**"]` for `gomod` now** so nested modules get version
  PRs too. Proactive, but may immediately churn a module we're about to remove.
- **other.**

## References

- INV-0006 — CI test gating (the `x/crypto` alerts live in the one Go harness a
  CI matrix would run; #40/#47/#46/#44/#50 feed that work).
- CLAUDE.md — `tools/bedrock-keyctl` Go-stdlib CVE history + the 1.26.4 bump.
- `.github/dependabot.yml` — the gomod `directory: "/"` gap.
- Dependabot alerts #1–#13 (all `golang.org/x/crypto` < 0.52.0,
  `modules/eks/cluster/test/go.mod`); PR #35 (the fix).
