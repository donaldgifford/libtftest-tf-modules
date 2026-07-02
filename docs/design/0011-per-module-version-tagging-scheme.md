---
id: DESIGN-0011
title: "Per-module version tagging scheme"
status: Draft
author: Donald Gifford
created: 2026-07-01
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0011: Per-module version tagging scheme

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-07-01

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Overview

Move this monorepo from **repo-wide semver tags** (`v0.1.0` … `v0.10.2`, one
version for the whole tree) to **per-module semver tags**, so each module is
versioned, changelogged, and pinned independently. A consumer should be able to
upgrade `rds/proxy` without appearing to change the version of `eks/cluster`,
and the auto-generated README table (`scripts/gen-readme.sh`) should show a
*real* per-module version rather than a derived proxy.

This is a **draft to work on later** — it frames the problem, lays out the
scheme with options, and records the open decisions. It does not commit to a
final format yet.

## Goals and Non-Goals

### Goals

- Independent **SemVer** per module (`MAJOR.MINOR.PATCH`), so unrelated modules
  don't share a version number.
- Consumers pin a module by a module-scoped git ref
  (`?ref=<module-tag>`), and `terraform init -upgrade` semantics are per module.
- **Automated** version bumps derived from Conventional Commits scoped to the
  module's files (feat → minor, fix → patch, `!`/`BREAKING CHANGE` → major).
- A per-module `CHANGELOG.md`, generated (git-cliff) from the same scoped
  history.
- The README generator reads the real per-module tag instead of the current
  "earliest tag containing the module's last code commit" heuristic.
- Backwards compatibility: existing repo-wide tags remain valid, resolvable refs
  (no history rewrite).

### Non-Goals

- Splitting the monorepo into per-module repositories (explicitly rejected — the
  monorepo + remote-state composition is the model, [ADR-0001](0001-*)).
- Changing the `modules/<service>/<module>/` source layout or how consumers
  reference `//modules/...` subdirectories.
- Rewriting or deleting historical `v0.x.y` tags.
- Designing the release *CLI* itself — the planned in-tree Go tool
  (techpivot-in-Go, integrated with docz) is a separate effort; this doc only
  defines the tag/version contract it (or an interim script) must implement.

## Background

Tags today are repo-wide and monotonic (`git tag` → `v0.1.0` … `v0.10.2`), cut
roughly once per merged module or fix. A consumer writes:

```hcl
source = "git::https://github.com/donaldgifford/libtftest-tf-modules.git//modules/rds/proxy?ref=v0.10.2"
```

`v0.10.2` says nothing about the *proxy* — it's a whole-repo marker. The
[README generator](../../scripts/gen-readme.sh) works around this by reporting,
per module, the earliest tag that contains the module's most recent top-level
`*.tf` commit. That is a useful proxy but imperfect: a cross-module PR (e.g. the
RDS Proxy PR that also added composition outputs to `rds/serverless`) stamps the
same tag on both modules, and doc/test-only commits are deliberately ignored.

The standing direction (per project memory and
[the versioning feedback](../../CLAUDE.md)) is **per-module semver tags**, with
a future custom Go CLI owning version + changelog + docs generation.

## Detailed Design

### Tag format

Git tag names may contain `/`. Candidate formats:

| Option | Example | Notes |
|--------|---------|-------|
| **A. Path-prefixed** | `rds/proxy/v1.0.0` | Mirrors the module path; greppable by prefix `rds/proxy/v*`; reads naturally in `?ref=`. |
| B. `modules/`-prefixed | `modules/rds/proxy/v1.0.0` | Same, but the redundant `modules/` prefix is noise. |
| C. Flat, delimited | `rds-proxy-v1.0.0` | No slashes (avoids any tooling that dislikes `/` in refs), but diverges from the path. |

**Leaning toward Option A** (`<service>/<module>/vX.Y.Z`). Consumer usage:

```hcl
source = "git::https://github.com/donaldgifford/libtftest-tf-modules.git//modules/rds/proxy?ref=rds/proxy/v1.0.0"
```

### Version computation

On merge to `main`, for each module whose *code* changed (top-level
`modules/<m>/*.tf` — the same file set the README generator already scopes to):

1. Find the module's latest existing tag (`git tag --list "<prefix>/v*"
   --sort=-v:refname | head -1`), default `v0.0.0`.
2. Scan Conventional Commit subjects touching `modules/<m>/` since that tag.
3. Bump: any `feat!`/`BREAKING CHANGE` → major; else any `feat` → minor; else
   any `fix`/`perf` → patch. No relevant commits → no release.
4. Create the annotated tag `<prefix>/vX.Y.Z` and regenerate the module's
   `CHANGELOG.md` (git-cliff scoped via `--include-path modules/<m>/`).

### Release tooling (interim vs. target)

- **Interim:** a shell script (`scripts/release-modules.sh`) + git-cliff config,
  invoked by a `just release` recipe and/or a CI job on merge to `main`.
- **Target:** the planned techpivot-in-Go CLI subsumes this (version + changelog
  + docs + templating), reading the same tag contract.

### README generator change

`module_version()` in `scripts/gen-readme.sh` switches from
"earliest tag containing the last code commit" to
"latest `<prefix>/v*` tag" (falling back to the repo-wide heuristic while both
schemes coexist during migration).

## API / Interface Changes

- **Consumer `?ref=` values** change from `v0.10.2` to `rds/proxy/v1.0.0`
  (module READMEs' source examples must be updated).
- **New `just` recipe(s):** `just release <module>` (dry-run + tag) and a CI
  entry point.
- **README generator:** `module_version()` reads per-module tags.
- **New per-module artifact:** `modules/<m>/CHANGELOG.md`.

## Data Model

- **Tag namespace:** `<service>/<module>/vX.Y.Z` alongside the frozen repo-wide
  `v0.x.y` tags. Both remain valid git refs.
- **Changelog:** one `CHANGELOG.md` per module, generated, never hand-edited.

## Testing Strategy

- Unit-test the bump computation (Conventional-Commit → semver) on a fixture
  history.
- Dry-run mode (`--check` / `--dry-run`) prints the computed next version + tag
  without creating anything; wire into CI as a preview on PRs.
- Verify `scripts/gen-readme.sh` reads the new tags (extend it to a table
  snapshot test).
- A smoke test that a `?ref=<module-tag>` `terraform init` resolves the module.

## Migration / Rollout Plan

1. **Freeze** repo-wide tags at `v0.10.2` (kept as historical, still resolvable).
2. **Seed** each module with an initial per-module tag on the current `main`
   commit (see Open Question Q2 for the starting version).
3. **Update** `scripts/gen-readme.sh` to prefer per-module tags, keeping the
   repo-wide heuristic as a fallback until every module is seeded; regenerate
   the README table.
4. **Wire** the interim release script into CI (tag + changelog on merge).
5. **Update** each module's `README.md` source example to the module-scoped ref.
6. **Revisit** when the Go CLI lands — it adopts the tag contract defined here.

## Open Questions

1. **Q1 — Tag format.** Path-prefixed `rds/proxy/v1.0.0` (Option A),
   `modules/`-prefixed (B), or flat `rds-proxy-v1.0.0` (C)? Leaning A.
2. **Q2 — Seed version.** Start every module at `v1.0.0` (declare them stable),
   or carry the current repo-wide minor (e.g. seed at `v0.10.0`) to signal
   pre-1.0? These modules are already applied-in-test and in use.
3. **Q3 — Tooling now vs. later.** Ship the interim shell + git-cliff release
   path now, or wait for the techpivot-in-Go CLI? (Interim unblocks the README
   generator sooner.)
4. **Q4 — Keep repo-wide tags in parallel?** Continue cutting a repo-wide
   `vX.Y.Z` as a "fleet snapshot" alongside per-module tags, or retire it once
   per-module tags exist?
5. **Q5 — Cross-module changes.** When one PR changes two modules (e.g. proxy +
   serverless outputs), both get independent bumps — confirm the scoping and
   changelog attribution handle shared commits cleanly.
6. **Q6 — GitHub Releases.** Cut a GitHub Release per module tag (with the
   changelog slice as notes), or tags only?
7. **Q7 — Renovate.** Can the repo's Renovate config track per-module tags for
   internal consumers, and does the format interact with its git-ref detection?

## References

- [`scripts/gen-readme.sh`](../../scripts/gen-readme.sh) — the README module
  table generator that consumes these versions.
- [ADR-0001](0001-*) — remote-state composition / monorepo model.
- [RFC-0001](../rfc) — module testing strategy (the coverage column's source).
- [git-cliff](https://git-cliff.org/) — changelog generation scoped by path.
- [docz](https://github.com/donaldgifford/docz) — doc lifecycle; the future CLI
  integrates with it.
