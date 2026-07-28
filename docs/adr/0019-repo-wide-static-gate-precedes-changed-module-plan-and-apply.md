---
id: ADR-0019
title: "Repo-wide static gate precedes changed-module plan and apply"
status: Accepted
author: Donald Gifford
created: 2026-07-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0019. Repo-wide static gate precedes changed-module plan and apply

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

Accepted (refines ADR-0018)

## Context

ADR-0018 / IMPL-0016 shipped a changed-module CI pipeline whose **plan tier ran
repo-wide** (`just tf all` per module across the whole inventory on every PR).
`just tf all` bundles `validate` + `lint` + `fmt` + plan-only `test` inside each
per-module plan job. Two problems surfaced in use:

1. **The static checks were invisible and non-gating.** `fmt` / `validate` /
   `tflint` / `terraform-docs` ran *inside* each `Plan (<module>)` job, so they
   were buried in job logs rather than surfaced as first-class checks, and — more
   importantly — the apply tiers only depended on `detect`, so they ran **in
   parallel** with the plan tier. A trivial `fmt` typo or `tflint` violation
   would not stop the expensive LocalStack apply jobs from spinning up.

2. **`terraform-docs` freshness was never enforced.** `USAGE.md` drift went
   uncaught; the committed docs had silently accumulated a spread of *resolved*
   provider versions (`6.45.0`/`6.46.0`/`6.47.0`/`6.52.0`/`6.54.0`) baked in from
   whatever `.terraform.lock.hcl` happened to exist when each was last generated
   (locks are gitignored — ADR reference below).

The maintainer's intent: run the cheap, deterministic static analysis across
**everything first**, and gate *every* downstream test on it — then narrow plan
and apply to only the modules that changed.

## Decision

Restructure the pipeline into a linear, gated DAG:

```text
static → detect → plan → { test-localstack, test-localstack-pro } → ci-gate
```

- **`static` (new, runs first, repo-wide).** `scripts/static-check.sh`
  (`just static`) runs, across **every** module: `terraform fmt -check
  -recursive` (repo-wide, one pass), `terraform validate`, `tflint`, and
  `terraform-docs`. It fails on any violation **or** on stale `USAGE.md`. No
  downstream job runs until it is green. `terraform-docs` is regenerated
  **lock-free** (the lock is removed first) so the Requirements/Providers tables
  show the version **constraint** (`~> 6.2`), which is deterministic across CI
  and local runs; freshness is `git diff --quiet HEAD -- '*USAGE.md'`. A shared
  `TF_PLUGIN_CACHE_DIR` downloads each provider once (~30s for all 14 modules).

- **Plan narrows to the changed set.** `scripts/changed-modules.sh` now emits
  `{changed, community, pro}` (all scoped to the change set; was `plan = all`).
  The `plan` tier is a matrix over `changed` running plan-only `just tf test`
  (validate/lint/fmt/docs now live in `static`). A change to a global file
  (justfile/mise.toml/.github/fixtures) still fans `changed` out to all modules,
  so those still get full plan coverage.

- **Apply tiers depend on plan.** `test-localstack` / `test-localstack-pro` now
  `needs: [detect, plan]`, so they only start once the plan tier is green (still
  behind the `CI_RUN_LOCALSTACK_APPLY` toggle + fork guard from IMPL-0016).

- **`ci-gate`** adds `static` to its `needs` and skip-tolerant loop.

This supersedes ADR-0018 / INV-0006 Q1a's "plan tier runs fleet-wide": full-repo
**compile** safety is retained by repo-wide `validate` in `static`, and only the
plan-*test* narrows to changed modules.

## Consequences

### Positive

- Format/lint/validate/docs are enforced repo-wide and **gate** every test, so no
  LocalStack apply burns minutes on a tree with a `fmt` typo or stale docs.
- `terraform-docs` freshness is now enforced and **deterministic** (lock-free,
  constraint form) — one-time normalization of all 14 `USAGE.md` removed the
  resolved-version drift.
- The static checks are a single, visible, fast first gate rather than being
  buried in per-module plan jobs.

### Negative

- The static gate is a serial repo-wide job (~2–4 min with the plugin cache); a
  broken module blocks the whole gate (intended — nothing should test on a broken
  tree). Could be parallelized into a matrix later if it becomes a bottleneck.

### Neutral

- Plan no longer runs repo-wide on unrelated modules; the safety it gave is now
  covered by repo-wide `validate` in `static` plus the global-file fan-out.

## Alternatives Considered

- **Per-module static matrix** (14 parallel jobs) instead of one serial job:
  faster, but needs a list-producing job before it and reads as many jobs rather
  than one gate. Deferred; can revisit if the serial gate is too slow.
- **Keep plan repo-wide**, only add the static gate: rejected — redundant with
  repo-wide `validate` and wastes CI on unrelated modules.
- **`terraform-docs settings.lockfile: false`** in each module config instead of
  removing the lock at generation time: equivalent effect, but 14 config edits
  vs. one script behavior; the script approach also guarantees determinism
  regardless of a module's config.

## References

- ADR-0018 — gate PRs with a repo-wide plan test and changed-module apply
  (refined by this ADR)
- INV-0006 — CI test-gating investigation (Q1a repo-wide plan superseded here)
- IMPL-0016 — CI test-gating pipeline implementation
- `.gitignore` — module `.terraform.lock.hcl` is gitignored (locks owned by the
  consuming Terragrunt unit), which is why lock-free doc generation is required
  for determinism
