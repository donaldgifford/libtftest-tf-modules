---
id: INV-0001
title: "Module scaffolding distribution and presence-check CI"
status: Open
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0001: Module scaffolding distribution and presence-check CI

**Status:** Open
**Author:** Donald Gifford
**Date:** 2026-05-15

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
  - [Distribution sub-investigation](#distribution-sub-investigation)
  - [Presence-check CI sub-investigation](#presence-check-ci-sub-investigation)
- [Environment](#environment)
- [Findings](#findings)
  - [Observation 1 — just tf new is a natural extension of the existing pattern](#observation-1--just-tf-new-is-a-natural-extension-of-the-existing-pattern)
  - [Observation 2 — tmpl/ dir is grep-able from CI](#observation-2--tmpl-dir-is-grep-able-from-ci)
  - [Observation 3 — Presence-check CI is independent of distribution mechanism](#observation-3--presence-check-ci-is-independent-of-distribution-mechanism)
  - [Observation 4 — The presence-check is more valuable than the distribution mechanism](#observation-4--the-presence-check-is-more-valuable-than-the-distribution-mechanism)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [References](#references)
<!--toc:end-->

## Question

Two related sub-questions:

1. **Distribution mechanism.** As we add four more modules
   (`managed-node-group`, `addons`, `pod-identity-access`,
   `ecr-pull-through-cache`) to a repo where `cluster` is the only
   filled-out module, what's the right mechanism for getting the
   uniform per-module scaffolding (`.tflint.hcl`,
   `.terraform-docs.yml`, `versions.tf`, USAGE.md markers, README
   shape) into each new module dir? Boilerplate templates have been
   ruled out — they go crusty in this org. Copy-paste-from-cluster
   works but drifts. Is `just tf new <path>` + a tmpl dir the right
   shape?

2. **Presence-check CI.** Independent of which distribution mechanism
   we pick, can we ship a CI smoke test that catches "module X is
   missing scaffolding file Y" *before* a PR review surfaces it
   manually? Concretely: does every `modules/eks/*/` directory have
   `versions.tf`, `.tflint.hcl`, `.terraform-docs.yml`, `README.md`,
   `USAGE.md` with `<!-- BEGIN_TF_DOCS -->` markers, and the
   five-file Terraform source set (`main.tf`, `variables.tf`,
   `outputs.tf`, plus optionally `locals.tf` / `data.tf`)?

## Hypothesis

1. **Distribution.** A top-level `tmpl/module/` directory holding the
   canonical scaffolding + a `just tf new <module-path>` recipe that
   copies and templates the dir into `modules/<module-path>` will
   beat both copy-paste-from-cluster and Boilerplate. Reasons: (a)
   the canonical source is one place and lives in the same repo as
   the consumers; (b) the just recipe is discoverable next to the
   existing `just tf <action> <module>` pattern; (c) no external
   binary (Boilerplate) to install/version-pin; (d) the templating
   can be as simple as `sed`-style substitution of module name into
   `versions.tf` provider blocks and README headers; (e) the
   tmpl dir is itself version-controlled, so drift is detectable.

2. **Presence-check CI.** A short bash script in `.github/workflows/`
   (or a new `just lint-modules` recipe wired into existing CI)
   iterating over `modules/eks/*/` directories and asserting file
   existence + a couple of grep checks will be sufficient. No need
   for a sophisticated linter or external tooling. Total
   implementation cost ≤ 1 hour.

Confidence on (1): medium-high. Confidence on (2): high.

## Context

The four pending implementations (IMPL-0002 / IMPL-0003 / IMPL-0004 /
IMPL-0005) each have a Phase 1 task: "Copy scaffolding files verbatim
from `modules/eks/cluster/`." That language is fine for the first
copy-paste but becomes a drift trap once cluster module updates its
scaffolding and the other four don't (or vice versa).

The CI smoke-test gap is sharper: today the only signal that a
module's scaffolding has gone missing is a `just tf <action>` failure
or a reviewer noticing. The CI workflows inherited from the libtftest
project don't validate Terraform module structure (CLAUDE.md §"CI
caveat" — they reference Go/Make/goreleaser that this repo doesn't
have).

Gruntwork Boilerplate has been explicitly ruled out by prior in-repo
experience: "we used boilerplate for this before and it gets a little
crusty in the repo." That removes the highest-velocity third-party
option from the table.

**Triggered by:** IMPL-0002 Open Question Q1 (resolved 2026-05-15
deferring to this INV).

## Approach

### Distribution sub-investigation

1. **Inventory canonical scaffolding files.** Diff the four files
   currently present in `modules/eks/cluster/` against what would
   need to be copied into each new module. Concretely:
   - `.tflint.hcl` — per-module config enabling `terraform`, `aws`,
     and the custom `terraform-style` plugins.
   - `.terraform-docs.yml` — `formatter: mb tbl`, `output.mode:
     inject`, USAGE.md target.
   - `versions.tf` — `terraform >= 1.1`, `hashicorp/aws ~> 6.2`.
   - `README.md` — short pointer (1–3 paragraphs).
   - `USAGE.md` — placeholder with the `<!-- BEGIN_TF_DOCS -->` /
     `<!-- END_TF_DOCS -->` markers terraform-docs uses for
     injection.
   - Terraform source stubs — `main.tf` header comment,
     `variables.tf` (empty or with a placeholder block),
     `outputs.tf` (empty), `locals.tf` (optional).

2. **Compare distribution options against the inventory.**

   | Option | Drift detectability | Setup cost | Maintenance | External deps |
   |---|---|---|---|---|
   | Copy-paste from cluster | Manual diff during review | Zero | Drifts silently | None |
   | `tmpl/` dir + `just tf new` | Single source; CI can grep tmpl vs modules | ~1 hour | Update tmpl/, rerun for new modules | None |
   | Gruntwork Boilerplate | Tooling diff (boilerplate.yml vs rendered) | Boilerplate install | "Crusty" per prior experience | Boilerplate binary |
   | Cookiecutter / similar | Tooling diff | pip+template repo | More steps to update | Python+cookiecutter |
   | Custom Go scaffolder | Compile + run | Days | Yet another tool to maintain | Go toolchain |

3. **Prototype the `just tf new` recipe** against the existing
   `justfile` action-dispatch pattern (`just tf <action> <module>`):

   ```just
   _tf-new module:
       #!/usr/bin/env bash
       set -euo pipefail
       target="modules/{{module}}"
       if [[ -d "$target" ]]; then
         echo "error: $target already exists" >&2; exit 1
       fi
       mkdir -p "$target"
       cp -R tmpl/module/. "$target/"
       name=$(basename "{{module}}")
       sed -i.bak "s/__MODULE_NAME__/${name}/g" "$target"/*.tf "$target/README.md" "$target/USAGE.md"
       rm "$target"/*.bak
       echo "created $target — populate variables.tf / main.tf next"
   ```

   Adapt for macOS `sed -i ''` if needed. Verify against creating a
   throwaway module dir, deleting it, repeating.

4. **Drift-detection CI.** Once `tmpl/module/` exists, add a CI
   check that compares each module's scaffolding files against the
   tmpl. The shape:

   ```bash
   # for each module under modules/eks/*/
   for f in .tflint.hcl .terraform-docs.yml; do
     if ! diff -q "tmpl/module/$f" "$module/$f" >/dev/null; then
       echo "DRIFT: $module/$f differs from tmpl/module/$f"; FAIL=1
     fi
   done
   ```

   Allowlist exceptions: per-module overrides should be possible
   (e.g., a module-specific tflint rule) — supported by a
   `# tmpl-allow-drift: <reason>` marker that the diff check looks
   for and skips.

### Presence-check CI sub-investigation

1. **Define the required-files manifest.** A list of files +
   optional grep patterns that every module must have:

   ```
   versions.tf            grep:'hashicorp/aws'
   .tflint.hcl
   .terraform-docs.yml
   README.md
   USAGE.md               grep:'<!-- BEGIN_TF_DOCS -->'
   main.tf
   variables.tf
   outputs.tf
   ```

2. **Implement as either:**
   - A `just lint-modules` recipe (matches existing justfile
     pattern; doesn't require changing CI workflow). Wired into
     `just docs lint` or a new top-level `just lint` umbrella.
   - A GitHub Actions workflow step. More visible at PR time;
     requires authoring CI yaml that doesn't currently exist for
     module-shape validation.

3. **Prototype the recipe:**

   ```just
   lint-modules:
       #!/usr/bin/env bash
       set -euo pipefail
       fail=0
       for mod in modules/eks/*/; do
         for required in versions.tf .tflint.hcl .terraform-docs.yml \
                         README.md USAGE.md main.tf variables.tf outputs.tf; do
           if [[ ! -f "$mod$required" ]]; then
             echo "MISSING: $mod$required"; fail=1
           fi
         done
         if ! grep -q '<!-- BEGIN_TF_DOCS -->' "$mod/USAGE.md" 2>/dev/null; then
           echo "MISSING: terraform-docs injection markers in $mod/USAGE.md"; fail=1
         fi
       done
       [[ $fail -eq 0 ]] || { echo "module-shape lint failed"; exit 1; }
   ```

4. **Verify against current state.** Run against `modules/eks/cluster/`
   (should pass) and against an empty stub like
   `modules/eks/addons/` (should fail — currently lacks the
   scaffolding). Tune the required-files manifest based on what
   actually causes false positives.

## Environment

| Component | Version / Value |
|-----------|----------------|
| Terraform | pinned in `mise.toml` |
| terraform-docs | pinned in `mise.toml` |
| tflint | pinned in `mise.toml` |
| just | 1.50.0 (supports `[working-directory]` but `cd && ...` pattern used) |
| Repo state | 5 modules total (1 filled-out cluster + 4 scaffold-only), AS of 2026-05-15 |

## Findings

To be filled in during the investigation. Initial sketch based on
public-context reasoning:

### Observation 1 — `just tf new` is a natural extension of the existing pattern

The `justfile` already dispatches `just tf <action> <module>` to
private `_tf-<action> <module>` recipes. Adding `_tf-new <module>`
matches that shape. Discoverability is high because users running
`just --list` see it next to validate/fmt/lint/docs/test.

### Observation 2 — `tmpl/` dir is grep-able from CI

A canonical `tmpl/module/.tflint.hcl` is one file. CI's drift check
is `diff -q tmpl/module/.tflint.hcl modules/eks/*/.tflint.hcl`. If
any module drifts, CI fails with a clear message. The allowlist
marker pattern (`# tmpl-allow-drift: <reason>`) keeps the door open
for legitimate per-module customization without making drift the
default.

### Observation 3 — Presence-check CI is independent of distribution mechanism

The presence-check recipe doesn't care HOW the scaffolding got there;
it only cares that it IS there. So the presence-check work can ship
before the tmpl/ + `just tf new` work, and catches the "Phase 1 of
IMPL-0002 forgot to copy `.terraform-docs.yml`" failure mode regardless
of which distribution mechanism wins.

### Observation 4 — The presence-check is more valuable than the distribution mechanism

For a fleet of 5–10 modules, copy-paste-from-cluster + presence-check
is probably sufficient. The distribution mechanism only starts to pay
off when (a) the scaffolding changes (and we need to update N
modules) or (b) the team adds modules frequently (and the copy-paste
gets tedious). Neither is true *right now*.

## Conclusion

To be filled in. Provisional answer based on the above reasoning:

**Answer (provisional):** Both yes — `just tf new` + `tmpl/` for
distribution, `just lint-modules` for presence-check. But ship them
in that order of priority (presence-check first, distribution second)
and don't conflate the two — they solve different problems.

## Recommendation

Provisional, pending the investigation steps actually being run:

1. **Ship `just lint-modules` first** (≤ 1 hour of work). Independent
   of distribution mechanism; catches the "missing scaffolding file"
   failure mode that all four pending IMPLs are vulnerable to in
   Phase 1.
2. **Wire `just lint-modules` into the existing `just docs lint`
   umbrella** or a new top-level `just lint` recipe so CI picks it
   up automatically.
3. **Then ship `tmpl/module/` + `just tf new`** as a follow-up. Update
   the Phase 1 task in IMPL-0002 / IMPL-0003 / IMPL-0004 / IMPL-0005
   to use `just tf new` instead of "copy verbatim from cluster
   module."
4. **Add a tmpl-drift CI check** *after* the tmpl/ dir exists and
   modules use it. Drift check is `diff -q tmpl/module/<file>
   modules/eks/<mod>/<file>` with the `# tmpl-allow-drift:` allowlist
   marker.

**Estimated effort:**
- `just lint-modules` + CI wiring: ≤ 1 hour.
- `tmpl/module/` + `just tf new`: 2–4 hours (including testing
  against a throwaway module create+destroy cycle).
- Drift CI: 1 hour after tmpl exists.

**Out of scope for this INV:**
- Migrating the four pending IMPLs' Phase 1 task language to use
  `just tf new`. That's a 4-line edit per IMPL doc done as a
  cleanup pass once the recipe exists.
- Replacing the inherited libtftest-era CI workflow files (CLAUDE.md
  §"CI caveat") — separate concern; tracked there.

## References

- IMPL-0002 — Managed Node Group Module Implementation (Open
  Question Q1, the trigger for this INV).
- IMPL-0003 / IMPL-0004 / IMPL-0005 — each has a Phase 1 task that
  benefits from the outcome of this investigation.
- CLAUDE.md §"Per-module conventions" — documents the current
  "copy these scaffolding files verbatim" convention.
- CLAUDE.md §"CI caveat" — notes that the inherited Go-shaped CI
  workflows don't validate Terraform module structure.
- justfile — the existing `just tf <action> <module>` action-dispatch
  pattern that `just tf new` extends and `just lint-modules`
  complements.
- Prior experience flagged by user: Gruntwork Boilerplate "gets a
  little crusty in the repo" — explicit non-option.
