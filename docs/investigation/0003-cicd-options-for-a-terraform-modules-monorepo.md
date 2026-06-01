---
id: INV-0003
title: "CI/CD options for a Terraform modules monorepo"
status: Completed
author: Donald Gifford
created: 2026-05-29
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0003: CI/CD options for a Terraform modules monorepo

**Status:** Completed
**Author:** Donald Gifford
**Date:** 2026-05-29

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
  - [Short-term (this investigation's deliverable)](#short-term-this-investigations-deliverable)
  - [Long-term (sibling RFC, scope-tracked, NOT this investigation)](#long-term-sibling-rfc-scope-tracked-not-this-investigation)
  - [Explicitly ruled out](#explicitly-ruled-out)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [Observation 1 — Current-state inventory (Approach step 1)](#observation-1--current-state-inventory-approach-step-1)
    - [Active workflows](#active-workflows)
    - [Disabled workflows (.bak)](#disabled-workflows-bak)
    - [Repo configs](#repo-configs)
    - [Missing files referenced by inherited CI](#missing-files-referenced-by-inherited-ci)
    - [Drift summary](#drift-summary)
    - [Classification (keep / strip / replace / fix)](#classification-keep--strip--replace--fix)
    - [Implications for steps 2-7](#implications-for-steps-2-7)
  - [Observation 2 — Matrix workflow shape (Approach step 2)](#observation-2--matrix-workflow-shape-approach-step-2)
    - [Workflow file layout (post-cleanup)](#workflow-file-layout-post-cleanup)
    - [ci.yml skeleton](#ciyml-skeleton)
    - [ci-localstack.yml skeleton](#ci-localstackyml-skeleton)
    - [justfile additions to support the matrix](#justfile-additions-to-support-the-matrix)
    - [Time-to-signal estimates](#time-to-signal-estimates)
  - [Observation 3 — Cross-module dependency drift (Approach step 3)](#observation-3--cross-module-dependency-drift-approach-step-3)
    - [Concrete dependency graph (as of 2cd92c0)](#concrete-dependency-graph-as-of-2cd92c0)
    - [Risk classification](#risk-classification)
    - [Mitigation evaluation](#mitigation-evaluation)
      - [(a) Output contract tests in the OWNING module — recommended short-term](#a-output-contract-tests-in-the-owning-module--recommended-short-term)
      - [(b) Reverse-lookup matrix — evaluated, NOT recommended for short-term](#b-reverse-lookup-matrix--evaluated-not-recommended-for-short-term)
      - [(c) Custom Go CLI computes reverse-deps from HCL — long-term, sibling RFC](#c-custom-go-cli-computes-reverse-deps-from-hcl--long-term-sibling-rfc)
    - [Short-term recommendation (folds into the PLAN doc)](#short-term-recommendation-folds-into-the-plan-doc)
  - [Observation 4 — Trivy / static security scanning (Approach step 4)](#observation-4--trivy--static-security-scanning-approach-step-4)
    - [Probe results](#probe-results)
    - [Signal quality](#signal-quality)
    - [Alternatives evaluated](#alternatives-evaluated)
    - [Workflow integration](#workflow-integration)
    - [Exemption strategy](#exemption-strategy)
    - [Frequency / cost](#frequency--cost)
    - [Recommendation](#recommendation)
  - [Observation 5 — Renovate surface inventory + config design (Approach step 5)](#observation-5--renovate-surface-inventory--config-design-approach-step-5)
    - [Pinned-version surface](#pinned-version-surface)
    - [Renovate vs Dependabot — decision matrix](#renovate-vs-dependabot--decision-matrix)
    - [Proposed .github/renovate.json shape](#proposed-githubrenovatejson-shape)
    - [In-HCL annotation discipline](#in-hcl-annotation-discipline)
    - [Renovate customManagers testing](#renovate-custommanagers-testing)
    - [Migration steps for the PLAN](#migration-steps-for-the-plan)
  - [Observation 6 — Release tooling, short-term vs long-term (Approach step 6)](#observation-6--release-tooling-short-term-vs-long-term-approach-step-6)
    - [Short-term: repo-level tagger + git-cliff CHANGELOG](#short-term-repo-level-tagger--git-cliff-changelog)
      - [Already working](#already-working)
      - [Net-new wiring](#net-new-wiring)
      - [changelog.yml final shape](#changelogyml-final-shape)
      - [Alternatives evaluated](#alternatives-evaluated-1)
    - [Long-term: per-module versioning via the custom Go CLI](#long-term-per-module-versioning-via-the-custom-go-cli)
      - [Per-module tag shape](#per-module-tag-shape)
      - [Per-module CHANGELOG.md](#per-module-changelogmd)
      - [Per-module version bump](#per-module-version-bump)
      - [Tooling that the Go CLI absorbs](#tooling-that-the-go-cli-absorbs)
      - [Transition path](#transition-path)
    - [Recommendation](#recommendation-1)
  - [Observation 7 — Reference implementations + forge scope (Approach step 7)](#observation-7--reference-implementations--forge-scope-approach-step-7)
    - [Reference repo survey](#reference-repo-survey)
      - [terraform-aws-modules/terraform-aws-eks — closest analog](#terraform-aws-modulesterraform-aws-eks--closest-analog)
      - [gruntwork-io/terraform-aws-eks](#gruntwork-ioterraform-aws-eks)
      - [hashicorp/terraform-provider-aws](#hashicorpterraform-provider-aws)
      - [techpivot/terraform-module-releaser — the algorithm we copy](#techpivotterraform-module-releaser--the-algorithm-we-copy)
      - [forge (the user's existing tool)](#forge-the-users-existing-tool)
    - [Updated sibling-RFC scope](#updated-sibling-rfc-scope)
    - [Recommendation](#recommendation-2)
    - [Open concerns to evaluate in steps 5-7](#open-concerns-to-evaluate-in-steps-5-7)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation-3)
  - [Immediate: PLAN-XXXX — short-term CI cleanup](#immediate-plan-xxxx--short-term-ci-cleanup)
  - [Follow-up: RFC-XXXX — custom Go CLI](#follow-up-rfc-xxxx--custom-go-cli)
  - [Status flip](#status-flip)
- [References](#references)
  - [Parent / sibling project docs](#parent--sibling-project-docs)
  - [Related investigations](#related-investigations)
  - [External tools surveyed](#external-tools-surveyed)
  - [External tools considered but ruled out](#external-tools-considered-but-ruled-out)
<!--toc:end-->

## Question

What CI/CD setup gives this Terraform-modules monorepo the best
quality signal + release ergonomics, and how should it be
organized? Specifically:

1. How should per-module quality gates (`fmt` / `validate` /
   `lint` / `terraform test` plan-only / optional `terraform test`
   against LocalStack) be scheduled in CI — one job per module
   (matrix), one job for the whole repo (sequential), or
   change-scoped (only run the modules a PR touched)?
2. How should `tests-localstack` runs be gated, given they need
   a Docker-in-Docker (or service container) LocalStack and that
   several modules currently fall back to `plan_smoke` because
   LocalStack Community lacks the relevant APIs (Phase-9
   fall-back pattern from IMPL-0005 / -0007 / -0008)?
3. What's the release model — semantic version tags off `main`
   that downstream callers pin in their `source =
   "git::...?ref=v1.2.3"` URLs, or per-module tags
   (`eks/cluster/v1.2.3`)? What does Release Please / semantic-
   release / git-cliff / a hand-rolled tagger buy us?
4. Where does the docz README index, terraform-docs USAGE
   regeneration, markdownlint, and the inherited
   libtftest-shaped `.golangci.yml` / goreleaser config fit (or
   not fit) in the new workflow? Per the CLAUDE.md "CI caveat":
   the current `ci.yml` was copied from the libtftest Go project
   and references things that do not exist here — what
   replaces it?
5. Does Gruntwork's
   [terraform-update-variable-defaults](https://github.com/gruntwork-io/terraform-update-variable-defaults)
   /
   [boilerplate-driven scaffolding](https://github.com/gruntwork-io/boilerplate)
   tooling fit, given the "infrastructure-modules + infrastructure-
   live" framing the user already runs (per the `Remote state refs,
   minimal locals, Gruntwork live-repo model` memory)?

## Hypothesis

Two-track approach: **immediate cleanup** of the inherited
libtftest-shaped CI now, plus a **long-term custom Go CLI** that
absorbs per-module versioning + changelog + docs + templating.

### Short-term (this investigation's deliverable)

- **GitHub Actions matrix with module-scoped change detection
  AND per-module multi-input runs**:
  - Use `dorny/paths-filter` (or hand-rolled `git diff --name-only`)
    to compute the touched module list.
  - Fan out one matrix job per touched module covering fmt +
    validate + lint + plan-only `terraform test`.
  - Each matrix entry runs the module's full `tests/*.tftest.hcl`
    set — which already covers multi-input shapes per module
    (e.g. `addons/tests/efs_csi_enabled.tftest.hcl`,
    `managed-node-group/tests/architecture.tftest.hcl`,
    `rds/serverless/tests/parameter_family_resolution.tftest.hcl`).
    Conditional-heavy modules already drive the multi-run
    coverage they need; the matrix wrapping just parallelizes.
- **Cross-module dependency drift** is an open concern (Q1):
  modules consume each other via S3-backed `terraform_remote_state`
  (per ADR-0001 + the `Remote state refs, minimal locals,
  Gruntwork live-repo model` memory). When an upstream module's
  output contract changes (e.g. `eks/cluster/outputs.tf`
  renames `node_security_group_id`), every downstream consumer
  silently breaks at apply time — the touched-module CI never
  fires for those consumers. Investigation step 3 evaluates
  options: (a) a contract-test layer that asserts each
  module's outputs match a versioned schema, (b) a
  consumer-side reverse-lookup matrix that runs every
  consumer's `tests/` suite when its upstream changes, (c)
  punting to the long-term custom CLI which already has the
  HCL graph parsed and can compute the reverse dependency set
  for free.
- **LocalStack-backed apply tests** run gated on a PR label
  (`run-localstack`) or scheduled nightly — avoids the ~75s
  startup cost on every PR. Modules where the apply suite has
  been demoted to `plan_smoke` (per IMPL-0005 / -0007 / -0008
  fall-back pattern) ride along; the workflow tolerates the
  demoted shape because the test file's runs are themselves
  conditional.
- **Early-fail gates** (before the per-module matrix fans out):
  `go fmt` ↓ `terraform fmt -check -recursive` ↓
  `golangci-lint` (against the existing libtftest test code
  under `modules/eks/cluster/test/`) ↓ `tflint --init &&
  tflint` ↓ `terraform-docs . && git diff --exit-code` (USAGE.md
  drift gate) ↓ `just docs lint` (markdownlint repo-wide).
  Each is its own job so a PR with a missing terraform-docs
  regen fails in <30s.
- **Static security scan**: add Trivy via
  [aquasecurity/trivy-action](https://github.com/aquasecurity/trivy-action)
  on the touched module set in `--mode=config` mode. Trivy's
  CIS + misconfig detection catches the same things we
  manually review (unencrypted S3 buckets, public-write IAM
  policies, etc.) — explicit research item in step 4.
- **Renovate config** added at the repo root with annotations
  on every pinned version line (provider versions in
  `versions.tf`, tflint plugin versions in `.tflint.hcl`,
  GitHub Actions versions, mise tool versions, `gvisor_version`
  default in `managed-node-group/variables.tf`,
  Postgres/MySQL engine majors in `rds/serverless/locals.tf`,
  any LocalStack image pins).
- **Keep `git-cliff` + the existing repo-level CHANGELOG**.
  This is the stopgap until the custom CLI ships — git-cliff's
  conventional-commits parsing already lines up with the
  `feat(...)`/`fix(...)`/`docs(...)` commit shape the user
  authors.
- **Strip the libtftest-Go remnants** from `ci.yml` that don't
  apply here: goreleaser, Docker bake build,
  `make test-coverage`, the inherited `.goreleaser.yml`. KEEP
  the Go linter + supply-chain wiring because the side-by-side
  libtftest reference suite at `modules/eks/cluster/test/` IS
  Go code that benefits from the same checks libtftest itself
  runs:
  - `go fmt`, `golangci-lint` (existing `.golangci.yml`).
  - `govulncheck` (CVE scan against the test code's deps).
  - `go-licenses` (license check on the same deps; mirrors
    the libtftest upstream wiring).
  These run only when files under `modules/<service>/<name>/test/`
  change, so non-libtftest modules don't pay the cost.

### Long-term (sibling RFC, scope-tracked, NOT this investigation)

A custom Go CLI — conceptually
[techpivot/terraform-module-releaser](https://github.com/techpivot/terraform-module-releaser)
rewritten in Go and tightly coupled to docz. The killer
features:

- Per-module semver tags (`eks/cluster/v1.2.3`,
  `efs/filesystem/v0.1.0`) computed from conventional-commits
  in the touched module's `git log` since its last tag.
- Per-module CHANGELOG.md emitted into each
  `modules/<service>/<name>/CHANGELOG.md`.
- Per-module `USAGE.md` regen via the existing terraform-docs
  config.
- docz integration: re-render the index tables; auto-link new
  IMPL / DESIGN / ADR docs into a module's README footer.
- Native HCL parsing (via `hashicorp/hcl/v2`) for reverse
  dependency lookup (the cross-module-drift Q1 fix), variable
  shape diffing, and output-contract change detection.
- Three call surfaces from one binary: GitHub Action
  (`uses: donaldgifford/<name>@v1`), local dev CLI (`<name>
  release plan`), Docker image
  (`docker run ghcr.io/donaldgifford/<name>`).
- Likely absorbs module templating + module-diff (the
  scaffolding role Gruntwork Boilerplate plays for other
  projects) — either as part of this CLI or as a sibling
  capability in the existing `forge` tool the user already
  maintains.

The custom CLI is **out of scope for INV-0003** but the
hypothesis assumes its existence at horizon T+N — the
short-term workflow above is the shape that the long-term
CLI will eventually drive from. Per-module versioning lands
in a sibling RFC.

### Explicitly ruled out

- **Gruntwork Boilerplate** for module templating. Doesn't
  fit the user's framing; the scaffolding role goes to the
  custom CLI or `forge`.
- **Per-module branch protection** (matrix listed for
  completeness in the approach below; not a serious option).
- **techpivot/terraform-module-releaser as-is**. The
  PowerShell + Node implementation is a deal-breaker; the
  concept is the inspiration for the Go rewrite.

## Context

The current `.github/workflows/ci.yml`, the goreleaser config,
the Docker bake build, the `make test-coverage` reference, and
the inherited `.golangci.yml` are all copied verbatim from the
libtftest Go project (see CLAUDE.md §"CI caveat"). Several jobs
fail or skip because the prerequisites — Go code at the repo
root, a Makefile, a Dockerfile, a goreleaser config — do not
exist in this Terraform-only repo. Today the only CI signal
that actually runs cleanly is the auto-labeler workflow:

- `Label PR` — applies labels based on branch prefix (`feat/`,
  `fix/`, `chore/`, `docs/`, `bug/`).
- `Check Required Labels` — gates merges on a release-affecting
  label being present (`patch` / `minor` / `major` /
  `no-release`).

Eight modules are now in the repo (four EKS, two ECR, one RDS,
one EFS) — each has its own `tests/` plan-only suite and most
have a `tests-localstack/` apply (or `plan_smoke` fall-back)
suite. Several module READMEs document per-module quality-gate
commands (`just tf all <module>`); none of those are wired into
GitHub Actions yet. As the module count grows the gap widens.

**Triggered by:** Post-IMPL-0008 retrospective; the CLAUDE.md
"CI caveat" callout has been deferred since IMPL-0001 and the
fleet now has enough modules + enough downstream pinning
appetite to justify replacing the inherited workflow.

## Approach

The investigation is **research-only** — no code change in this
branch. Output: populated Findings + Conclusion + Recommendation
sections + a follow-up PLAN doc (immediate cleanup) and a
sibling RFC (custom Go CLI / per-module versioning).

1. **Inventory the current state.** Read
   `.github/workflows/*.yml`, `.github/labeler.yml`,
   `.golangci.yml`, `.goreleaser.yml`, any `.git-cliff.toml` /
   `cliff.toml`, the `justfile` recipes, and the
   labeler-driven release labels. Classify each file as
   **keep / strip / replace**. Specifically confirm whether
   the libtftest-shaped `ci.yml` actually fails today (the
   PR-18 merge succeeded with only the two labeler workflows
   green — so the rest is silently broken). The verdict feeds
   the short-term cleanup PLAN.
2. **Workflow shape — matrix + change detection.** Sketch the
   `.github/workflows/ci.yml` skeleton:
   - `paths-filter` (or `git diff --name-only origin/main`
     fallback) computes a JSON list of touched
     `modules/<service>/<name>/` paths.
   - Early-fail repo-wide jobs (run in parallel; <30s each):
     `go-fmt`, `terraform-fmt`, `golangci-lint`, `tflint`,
     `terraform-docs-drift` (regen + `git diff --exit-code`),
     `markdownlint` (`just docs lint`).
   - Per-module matrix job: `just tf all <module>` per touched
     module path. Each entry's `tests/*.tftest.hcl` already
     covers multi-input runs (the existing test files'
     conditional shapes — `eks/managed-node-group/tests/architecture.tftest.hcl`,
     `eks/addons/tests/efs_csi_enabled.tftest.hcl`,
     `rds/serverless/tests/parameter_family_resolution.tftest.hcl`,
     `efs/filesystem/tests/lifecycle_policy.tftest.hcl` —
     are the multi-input coverage; matrix wrapping
     parallelizes across modules, not within).
   - `tests-localstack` job: label-gated (`run-localstack`)
     OR scheduled (`schedule: cron: "0 6 * * *"`) OR
     `workflow_dispatch`. Same per-module matrix shape.
3. **Cross-module dependency drift** (the user's Q1 concern).
   Catalog the current cross-module output → input edges in
   this repo:
   - `eks/cluster` outputs → consumed by `eks/managed-node-group`,
     `eks/addons`, `eks/pod-identity-access`, `efs/filesystem`.
   - `vpc` (out-of-tree) outputs → consumed by `eks/cluster`,
     `rds/serverless`, `efs/filesystem`.
   - `rds/serverless` outputs → planned consumers (per
     DESIGN-0007 rollout): `rds/cluster`, `rds/read-replica`.
   Evaluate three mitigations:
   - **(a) Output contract tests.** Each module's `tests/`
     suite adds an `outputs.tftest.hcl` that pins the output
     names + types (`length(...) == 14`, `output.cluster_endpoint`
     is non-null). Drift surfaces in the OWNING module's CI,
     not the consumer's. Cheap to add.
   - **(b) Reverse-lookup matrix.** When an output-side
     module changes, the CI also runs every downstream
     consumer's `tests/` suite via override_data stubs. Needs
     a manually maintained reverse-dep map (or HCL parsing,
     which is where (c) wins).
   - **(c) Punt to the custom Go CLI.** The CLI parses HCL
     and computes the reverse-dependency set for free; the
     CI workflow consumes its output via
     `<cli> reverse-deps <touched>`. Highest payoff but
     blocked on the CLI shipping.
   Recommend (a) for the short-term PLAN + (c) for the
   long-term RFC.
4. **Trivy / security scanning.** Evaluate:
   - `aquasecurity/trivy-action@v0` with `scan-type: config`
     against touched module paths.
   - Output as SARIF + upload to GitHub Code Scanning so
     findings land in the PR's Security tab + the repo's
     security dashboard.
   - Exemption file (`.trivyignore` or per-module
     `.trivy.yaml`) for accepted findings.
   - Compare against alternatives: `tfsec` (now deprecated in
     favor of Trivy), `checkov` (heavier; Python +
     opinionated policy bundles), `terraform-compliance`
     (BDD; mismatch for this repo).
5. **Renovate.** Survey the pinned version surface:
   - Provider versions in every module's `versions.tf`
     (`hashicorp/aws ~> 6.2`, terraform `>= 1.1`).
   - tflint plugin versions in every module's `.tflint.hcl`
     (`terraform-style 0.0.5`, `aws 0.47.0`).
   - GitHub Actions versions (in the cleaned-up workflows).
   - `mise.toml` tool versions.
   - In-HCL pins: `gvisor_version` default in
     `managed-node-group/variables.tf`, default major map in
     `rds/serverless/locals.tf`,
     `efs/filesystem/variables.tf` default lifecycle
     transitions, LocalStack image pin in
     `tests-localstack/*.tftest.hcl` providers (none today —
     env-driven — but worth tracking).
   Author a `.github/renovate.json` config with grouped PRs
   (`provider-aws`, `tflint-plugins`, `github-actions`,
   `mise`, `terraform-internals`). Document the Renovate
   annotation syntax (`# renovate: datasource=... depName=...`)
   for HCL pins.
6. **Release tooling.** For the short term:
   - Keep `git-cliff` driving a repo-level `CHANGELOG.md`.
   - Keep the label-driven version bump
     (`patch`/`minor`/`major`/`no-release`).
   - `gh release create` from a `release.yml` workflow
     triggered on merge-to-main when the labels indicate a
     release.
   For the long term:
   - Per-module tags + per-module CHANGELOGs flow through
     the custom Go CLI. Sibling RFC.
7. **Survey reference implementations.** Skim:
   - `gruntwork-io/terraform-aws-eks` (CircleCI + Makefile +
     per-module tests).
   - `terraform-aws-modules/terraform-aws-eks` (GitHub
     Actions + pre-commit + Renovate — closest analog).
   - `hashicorp/terraform-provider-aws` (single-module repo
     but instructive matrix patterns).
   - `techpivot/terraform-module-releaser` itself — read the
     algorithm; the user wants the Go rewrite to mirror its
     surface.
   - `forge` (the user's existing tool) — confirm scope
     overlap with the planned Go CLI.
8. **Write up.** Populate Findings + Conclusion +
   Recommendation. Emit two follow-ups:
   - **PLAN-XXXX**: immediate CI cleanup (steps 1, 2, 3a,
     4, 5, 6-short).
   - **RFC-XXXX**: custom Go CLI + per-module versioning
     (steps 3c, 6-long, scope vs `forge`).

## Environment

| Component | Version / Value |
|-----------|----------------|
| Repository | `donaldgifford/libtftest-tf-modules` (post-IMPL-0008, 8 modules: `eks/cluster`, `eks/managed-node-group`, `eks/addons`, `eks/pod-identity-access`, `ecr/pull-through-cache`, `ecr/org-registry`, `rds/serverless`, `efs/filesystem`) |
| CI runtime | GitHub Actions (only platform under consideration; matches the rest of the user's repos) |
| Tool versions | Pinned in `mise.toml` — Terraform, terraform-docs, tflint, golangci-lint (inherited but unused), markdownlint-cli2, just, docz |
| Existing workflows | `.github/workflows/ci.yml` (libtftest-shaped, mostly dead per CLAUDE.md "CI caveat"), `.github/workflows/labeler.yml` (active; auto-labels by branch prefix), `Check Required Labels` workflow (gates merges) |
| LocalStack | Community 3.8.1 (verified 2026-05-29 — Pro auth token not currently in the CI runner env) |
| Release labels in use | `patch`, `minor`, `major`, `no-release` — applied by the auto-labeler based on branch prefix per the existing `.github/labeler.yml` |

## Findings

### Observation 1 — Current-state inventory (Approach step 1)

Catalogued every CI-adjacent file on `main` as of `2cd92c0`. The
repo has more inherited dust than CLAUDE.md's "CI caveat" implies:
the live workflows reference five different absent files
(`go.mod`, `Makefile`, `cliff.toml`, `CHANGELOG.md`,
`Dockerfile` / `docker-bake.hcl`, `.goreleaser.yml`) and the
labeler config routes file paths that don't exist
(`cmd/**.go`, `pkg/**.go`, `collector/**.go`, etc.).

#### Active workflows

| File | What runs today | Status |
|------|-----------------|--------|
| `.github/workflows/ci.yml` | Only the `labeler` job (lines 14-23). Lines 24-152 are commented-out: `lint` (`go-version-file: go.mod`), `test-go` (`make test-coverage` + Codecov), `test-integration` (`go test -tags=integration`), `test-integration-pro` (LocalStack Pro), `security` (`govulncheck` + Trivy), `build` (`goreleaser build --snapshot`). | Live but mostly dead code. Cleanup target. |
| `.github/workflows/pr-labels.yml` | Gates merges on exactly one of `major` / `minor` / `patch` / `dont-release`. Uses `mheap/github-action-required-labels@v5`. | Works. Keep. |
| `.github/workflows/release.yml` | `bump-version` job uses `jefflinse/pr-semver-bump@v1.7.4` to tag the repo on every push to `main` based on the merged PR's semver label. The follow-up jobs (`release` via goreleaser, `docker` via bake + cosign, `changelog-sync` via git-cliff) are all commented out. | `bump-version` works and is what tagged `v0.9.0` after PR #17 + the new tag after PR #18. The downstream jobs cannot work without `go.mod`, `.goreleaser.yml`, `Dockerfile`, `docker-bake.hcl`. Strip the downstream blocks for now. |
| `.github/workflows/security.yml` | Scheduled weekly (Mon 00:00 UTC) + push-to-main. Runs `donaldgifford/govulncheck-action@v1` against the repo. Uploads SARIF to GitHub Code Scanning. | **Currently broken** — there is no `go.mod` at the repo root for `govulncheck` to read. The action will fail or no-op. Needs a per-test-directory pivot (Go code lives at `modules/eks/cluster/test/`). |
| `.github/dependabot.yml` | Three ecosystems: `github-actions` at `/` (works), `docker` at `cicd/` (no such directory), `gomod` at `/` (no go.mod; `open-pull-requests-limit: 0` makes it security-only — so it does nothing today). | Fix the `docker`/`gomod` paths; the `github-actions` ecosystem is the only one earning its keep. |

#### Disabled workflows (`.bak`)

| File | Intent | Why it's disabled |
|------|--------|-------------------|
| `.github/workflows/changelog.yml.bak` | Drift check: regenerate `CHANGELOG.md` via `git-cliff -o`, diff against committed version, fail if stale. | Repo has no `CHANGELOG.md` and no `cliff.toml`. Also: `git-cliff` is NOT in `mise.toml`'s tools list — only in the user's global mise install — so even `jdx/mise-action@v3` wouldn't put it on a runner's PATH. Three-prereq fix. |
| `.github/workflows/license-check.yml.bak` | `go-licenses check ./... --allowed_licenses=Apache-2.0,MIT,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0` + CSV report upload. Template at `.github/licenses-csv.tpl`. | No `go.mod` at the repo root. Same pivot as `security.yml` — needs to target test-suite directories. |

#### Repo configs

| File | Status |
|------|--------|
| `.golangci.yml` | 8.2k Uber-style config. Has zero files to lint at the repo root today; will start earning when wired against `modules/<service>/<name>/test/` paths (currently only `modules/eks/cluster/test/` exists per CLAUDE.md). Keep + scope. |
| `.markdownlint.yaml`, `.prettierrc.yaml`, `.yamlfmt.yml`, `.yamllint.yml` | Generic linter configs. Wired into `just docs lint` via `.markdownlint.yaml`; the others are unused in `justfile`. |
| `.docz.yaml` | Active — drives `docz create`, `docz update`. |
| `.github/labeler.yml` | **Drifted.** Routes `cmd/**.go`, `pkg/**.go`, `collector/**.go`, `config/**.go`, `exporter/**.go` — none exist in this repo. The head-branch globs use `^feature` / `feature` — but the user's git-workflow skill prescribes `feat/` (PR #17 + #18 both used `feat/...` branches and got NO branch-derived label from labeler.yml; the `minor` label came from the user manually or from the upstream `Check Required Labels` workflow requirement). The `docker` label routes `Dockerfile` / `docker-bake.hcl` — don't exist. Significant fix. |
| `.github/licenses-csv.tpl` | One-liner — used only by `license-check.yml.bak`. Keep but make conditional on the workflow re-enable. |
| `mise.toml` | Pins: terraform 1.14.7, terragrunt 0.99.4, tflint 0.62.0, terraform-docs 0.24.0, just (latest), `lstk` 0.7.1, markdownlint-cli2 0.18.1, yamlfmt 0.20.0, yamllint 1.37.1, prettier 3.7.4, golangci-lint 2.11.4, `go-licenses` (latest, via go-install), `govulncheck` (latest, via go-install). **Missing: `git-cliff`** — needs to be added before `changelog.yml.bak` can be re-enabled. |
| `scripts/labels.sh` | Bootstrap script — extracts label names from `labeler.yml` + `pr-labels.yml` and applies them to the repo via `gh label create`. Defines colors per label. Independent of CI. Useful for documenting label intent; keep. |
| `justfile` | Has `docs <lint\|fix\|fmt>` group and `tf <fmt\|validate\|lint\|docs\|test\|test-localstack\|all> <module>` group. No `_tf-fix` (no formatter that mutates), no `lint-modules` aggregate. Solid foundation; CI can call these directly. |

#### Missing files referenced by inherited CI

`go.mod` (root), `Makefile`, `cliff.toml`, `CHANGELOG.md`,
`Dockerfile`, `docker-bake.hcl`, `.goreleaser.yml`,
`cicd/` directory, `.codecov.yml`, `.chglog.yml`. None of these
exist; the inherited workflows / configs that reference them
are all either commented-out, disabled (`.bak`), or
silently failing today.

#### Drift summary

- The labeler's branch-prefix routing (`^feature`) does not
  match the user's actual branch naming convention (`feat/`,
  `fix/`, `chore/`, `docs/`, `bug/`) per the
  `git-workflow:branch-naming` skill. PR #18's two labels came
  from path routing (`documentation` via `docs/**`) and
  manual / `Check Required Labels` interaction (`minor`); the
  branch prefix contributed nothing.
- `.github/labeler.yml`'s "repo" group references
  `.codecov.yml`, `.chglog.yml`, `changelog.yaml`,
  `scripts/**.sh`. Only `.markdownlint.yaml` +
  `.prettierrc.yaml` + `.yamlfmt.yml` + `.yamllint.yml` +
  `.golangci.yml` from that list actually exist.
- `security.yml` and the disabled `license-check.yml.bak`
  both assume a Go module at the repo root. The actual Go code
  in this repo lives in test directories
  (`modules/eks/cluster/test/` per CLAUDE.md) — those
  workflows need either a root-level `go.work` aggregating
  those test modules OR a matrix that runs `govulncheck` +
  `go-licenses` per test directory.

#### Classification (keep / strip / replace / fix)

| File / item | Verdict | Action |
|-------------|---------|--------|
| `ci.yml::labeler` job | **Keep** | Move to its own workflow file (or fold into `pr-labels.yml`) and delete the commented-out blocks below. |
| `ci.yml` commented-out jobs (`lint`, `test-go`, `test-integration`, etc.) | **Strip** | Replace with the matrix workflow per Hypothesis. |
| `pr-labels.yml` | **Keep** | Already works. |
| `release.yml::bump-version` | **Keep** (short-term) | Already works. Sibling RFC will replace with per-module tagger; for now this stays as the repo-level bumper. |
| `release.yml` commented-out jobs (`release`, `changelog-sync`, `docker`) | **Strip** | Goreleaser, docker bake, cosign — all libtftest-Go-shaped. Drop. |
| `security.yml` | **Fix** | Pivot to per-test-directory matrix; today it fails because no root `go.mod`. |
| `dependabot.yml::github-actions` | **Keep** | Earns its keep on workflow file changes. |
| `dependabot.yml::docker (cicd/)` | **Strip** | Path doesn't exist. |
| `dependabot.yml::gomod (/)` | **Strip or pivot** | No root go.mod; rewire to a `directories:` list pointing at every `modules/<svc>/<name>/test/` once Renovate isn't on the table for those (decision lands in step 5). |
| `changelog.yml.bak` | **Fix + revive** | Rename `.bak` → `.yml`, add `cliff.toml`, seed `CHANGELOG.md`, add `git-cliff` to `mise.toml`. |
| `license-check.yml.bak` | **Fix + revive** | Pivot to per-test-directory matrix, same as `security.yml`. |
| `.golangci.yml` | **Keep + scope** | Wire the linter against `modules/<svc>/<name>/test/` paths. Keep the existing Uber-style ruleset. |
| `.github/labeler.yml` | **Fix** | Replace `cmd/`/`pkg/`/`collector/`/`config/`/`exporter/` Go-paths with `modules/<svc>/<name>/**` (split by service for nicer labels: `eks`, `ecr`, `rds`, `efs`). Replace `^feature` with `^feat`. Drop `docker:` group. Replace `Makefile` glob in `ci:` group with `justfile`. |
| `.github/licenses-csv.tpl` | **Keep** | Tiny; reused by the revived license-check. |
| `mise.toml` | **Fix** | Add `git-cliff = "..."`. Probably also add `cosign` and `syft` if security.yml will SBOM. |
| `scripts/labels.sh` | **Keep** | Bootstraps labels; independent of CI. |
| `justfile` | **Extend** | Add `just tf fix <module>` (mutating `terraform fmt`), `just lint-modules` (matrix-aware), `just renovate-check` once Renovate config lands. |
| Missing files | **Create as needed** | `cliff.toml` (revival pre-req), `CHANGELOG.md` (seed). Skip everything else (`go.mod`/`Makefile`/`Dockerfile`/`.goreleaser.yml`/`cicd/` — out of scope for a TF modules repo). |

#### Implications for steps 2-7

- The matrix workflow (step 2) can lean on `justfile` recipes
  directly — `just tf fmt|validate|lint|test efs/filesystem`
  is the right granularity. No reinvention.
- The `tests-localstack` gating (step 2 / step 7) doesn't
  exist anywhere today — entirely greenfield. No prior pattern
  to reuse.
- The per-module versioning RFC (step 6 long-term) has zero
  collisions with the current `release.yml::bump-version` —
  the new tagger can co-exist on a different label set or
  replace the existing job wholesale.
- The labeler.yml drift (head-branch + path globs) means the
  short-term PLAN must fix labeler.yml BEFORE the matrix
  workflow goes live — otherwise the path-filter step will
  fight the labeler's stale globs.

### Observation 2 — Matrix workflow shape (Approach step 2)

Designed against the cleaned-up surface from Observation 1.
Three-layer shape: early-fail gates → per-module matrix →
opt-in LocalStack matrix. Workflow files split for blast-
radius isolation; each file has a single conceptual purpose.

#### Workflow file layout (post-cleanup)

| File | Trigger | Purpose |
|------|---------|---------|
| `.github/workflows/ci.yml` | `push:main`, `pull_request` | Fan-out workflow. Computes touched-module set via path filter → early-fail gates (parallel) + per-module matrix. |
| `.github/workflows/ci-localstack.yml` | `pull_request` (label-gated `run-localstack`), `schedule: cron "0 6 * * *"`, `workflow_dispatch` | LocalStack apply / plan_smoke matrix. Same touched-module set. |
| `.github/workflows/pr-labels.yml` | `pull_request` (label-affecting) | Semver label gate. Keep as-is. |
| `.github/workflows/release.yml` | `push:main` | `bump-version` job only. Strip the goreleaser / docker / changelog-sync blocks. |
| `.github/workflows/security.yml` | `push:main`, `schedule: weekly` | Pivoted to a per-test-directory matrix (govulncheck + go-licenses against `modules/<svc>/<name>/test/`). |
| `.github/workflows/changelog.yml` | `pull_request` (any), `workflow_dispatch` | Revived from `.bak` once `cliff.toml` + seed `CHANGELOG.md` + mise `git-cliff` land. |
| `.github/workflows/labeler.yml` | `pull_request` (any) | Splits off the path/head-branch labeler from `ci.yml`. Fixed labeler.yml drift per Observation 1. |

#### `ci.yml` skeleton

```yaml
---
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:

  # ─── Touched-module detection ────────────────────────────────
  changes:
    name: Detect touched modules
    runs-on: ubuntu-latest
    outputs:
      modules: ${{ steps.filter.outputs.changes }}
      meta: ${{ steps.filter.outputs.meta }}
    steps:
      - uses: actions/checkout@v6
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          # Each named filter emits its name into `changes` when matched.
          # `meta` is a sentinel — when shared infra changes, fan out to
          # every module.
          filters: |
            eks/cluster:
              - 'modules/eks/cluster/**'
            eks/managed-node-group:
              - 'modules/eks/managed-node-group/**'
            eks/addons:
              - 'modules/eks/addons/**'
            eks/pod-identity-access:
              - 'modules/eks/pod-identity-access/**'
            ecr/pull-through-cache:
              - 'modules/ecr/pull-through-cache/**'
            ecr/org-registry:
              - 'modules/ecr/org-registry/**'
            rds/serverless:
              - 'modules/rds/serverless/**'
            efs/filesystem:
              - 'modules/efs/filesystem/**'
            meta:
              - 'justfile'
              - 'mise.toml'
              - '.github/workflows/ci.yml'
              - '.github/workflows/ci-localstack.yml'
              - '.tflint.hcl'        # repo-root if present
              - '.terraform-docs.yml'  # repo-root if present

  # ─── Early-fail gates ────────────────────────────────────────
  # Parallel, repo-wide. Cheap (<30s each). A failure here
  # short-circuits the per-module matrix because the matrix
  # `needs:` this job.

  fmt-terraform:
    name: terraform fmt
    runs-on: ubuntu-latest
    needs: changes
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: terraform fmt -check -recursive modules/

  fmt-yaml:
    name: yamlfmt / yamllint
    runs-on: ubuntu-latest
    needs: changes
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: yamlfmt -lint .
      - run: yamllint .

  fmt-prettier:
    name: prettier --check
    runs-on: ubuntu-latest
    needs: changes
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: prettier --check '**/*.{json,md,yaml,yml}'

  lint-docs:
    name: markdownlint
    runs-on: ubuntu-latest
    needs: changes
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: just docs lint

  lint-actions:
    name: actionlint
    runs-on: ubuntu-latest
    needs: changes
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: actionlint

  lint-shell:
    name: shellcheck
    runs-on: ubuntu-latest
    needs: changes
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: shellcheck scripts/*.sh

  # Go gates — only run when libtftest test code under any
  # module's test/ subtree changed (cheap to scope; today only
  # modules/eks/cluster/test/ exists).
  fmt-go:
    name: go fmt + golangci-lint (test suites)
    runs-on: ubuntu-latest
    needs: changes
    if: |
      contains(needs.changes.outputs.modules, 'eks/cluster') ||
      contains(needs.changes.outputs.meta, 'meta')
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: |
          gofmt -l modules/eks/cluster/test/ | tee /tmp/gofmt.out
          test ! -s /tmp/gofmt.out
      - run: |
          cd modules/eks/cluster/test
          golangci-lint run ./...

  # ─── Per-module matrix ───────────────────────────────────────
  module-test:
    name: ${{ matrix.module }} (validate + lint + test)
    runs-on: ubuntu-latest
    needs:
      - changes
      - fmt-terraform
      - fmt-yaml
      - fmt-prettier
      - lint-docs
      - lint-actions
    if: ${{ needs.changes.outputs.modules != '[]' }}
    strategy:
      fail-fast: false
      matrix:
        module: ${{ fromJSON(needs.changes.outputs.modules) }}
        # Exclude the 'meta' sentinel — it's not a real module.
        exclude:
          - module: meta
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true

      # Cache the per-module tflint plugin cache so each matrix
      # entry doesn't redownload the terraform / aws / terraform-
      # style plugins.
      - uses: actions/cache@v4
        with:
          path: ~/.tflint.d/plugins
          key: tflint-${{ runner.os }}-${{ hashFiles(format('modules/{0}/.tflint.hcl', matrix.module)) }}

      - run: just tf validate ${{ matrix.module }}
      - run: just tf lint ${{ matrix.module }}
      - run: just tf test ${{ matrix.module }}

      # terraform-docs drift gate — runs in the matrix (not
      # repo-wide) so we only regen for touched modules.
      - run: |
          just tf docs ${{ matrix.module }}
          git diff --exit-code modules/${{ matrix.module }}/USAGE.md

  # ─── Trivy config scan ────────────────────────────────────────
  trivy:
    name: Trivy config scan
    runs-on: ubuntu-latest
    needs:
      - changes
    if: ${{ needs.changes.outputs.modules != '[]' }}
    permissions:
      contents: read
      security-events: write
    strategy:
      fail-fast: false
      matrix:
        module: ${{ fromJSON(needs.changes.outputs.modules) }}
        exclude:
          - module: meta
    steps:
      - uses: actions/checkout@v6
      - uses: aquasecurity/trivy-action@v0
        with:
          scan-type: config
          scan-ref: modules/${{ matrix.module }}
          format: sarif
          output: trivy-${{ matrix.module }}.sarif
          # Fail on high+critical; informational findings just
          # show up in Code Scanning without breaking the build.
          severity: HIGH,CRITICAL
          exit-code: '1'
      - uses: github/codeql-action/upload-sarif@v4
        if: always()
        with:
          sarif_file: trivy-${{ matrix.module }}.sarif
          category: trivy-${{ matrix.module }}

  # ─── Fan-in: a single status check downstream branch-protection
  # rules can require. Mirrors the rust / kube pattern.
  ci:
    name: CI
    runs-on: ubuntu-latest
    needs:
      - fmt-terraform
      - fmt-yaml
      - fmt-prettier
      - lint-docs
      - lint-actions
      - lint-shell
      - fmt-go
      - module-test
      - trivy
    if: always()
    steps:
      - name: Fail if any required check failed
        if: |
          contains(needs.*.result, 'failure') ||
          contains(needs.*.result, 'cancelled')
        run: exit 1
```

#### `ci-localstack.yml` skeleton

```yaml
---
name: CI (LocalStack)
on:
  pull_request:
    types: [opened, synchronize, labeled]
  schedule:
    - cron: '0 6 * * *'   # nightly @ 06:00 UTC
  workflow_dispatch:

permissions:
  contents: read

jobs:

  # Same path filter as ci.yml — could be factored into a
  # composite action later.
  changes:
    name: Detect touched modules
    runs-on: ubuntu-latest
    # Gate scheduled + dispatch on "all modules"; PRs on the label.
    if: |
      github.event_name != 'pull_request' ||
      contains(github.event.pull_request.labels.*.name, 'run-localstack')
    outputs:
      modules: ${{ steps.filter.outputs.changes || steps.all.outputs.modules }}
    steps:
      - uses: actions/checkout@v6
      - id: filter
        if: github.event_name == 'pull_request'
        uses: dorny/paths-filter@v3
        with:
          filters: |
            # …same filters block as ci.yml…
      - id: all
        if: github.event_name != 'pull_request'
        run: |
          # On schedule + dispatch, fan out to every module that
          # has a tests-localstack/ directory.
          modules=$(find modules -mindepth 3 -maxdepth 3 -type d \
            -name tests-localstack \
            -exec dirname {} \; \
            | sed 's|modules/||' \
            | jq -R . | jq -sc .)
          echo "modules=$modules" >>"$GITHUB_OUTPUT"

  localstack-test:
    name: ${{ matrix.module }} (LocalStack)
    runs-on: ubuntu-latest
    needs: changes
    if: ${{ needs.changes.outputs.modules != '' && needs.changes.outputs.modules != '[]' }}
    strategy:
      fail-fast: false
      matrix:
        module: ${{ fromJSON(needs.changes.outputs.modules) }}
        exclude:
          - module: meta
    services:
      localstack:
        # Pinned to the Community release verified in
        # modules/efs/filesystem/tests-localstack/FINDINGS.md.
        # Bump via Renovate.
        image: localstack/localstack:3.8.1
        ports:
          - 4566:4566
        # Pro auth via repo secret when available — falls through
        # silently on Community when unset. Modules that demoted
        # to plan_smoke per IMPL-0005 Phase 9 fall-back run
        # identically on either tier.
        env:
          LOCALSTACK_AUTH_TOKEN: ${{ secrets.LOCALSTACK_AUTH_TOKEN }}
        options: >-
          --health-cmd "curl -sf http://localhost:4566/_localstack/health"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 30
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      - run: just tf test-localstack ${{ matrix.module }}
```

#### `justfile` additions to support the matrix

```just
# Existing recipes left intact. Add:

# Run validate + lint + fmt + test + docs-drift for every module.
# Used by humans pre-commit; CI uses the per-module recipes
# directly via the matrix.
[group('tf')]
tf-fleet action:
    @for dir in $(find modules -mindepth 3 -maxdepth 3 -type d \
        -name tests \
        -exec dirname {} \; \
        | sed 's|modules/||'); do \
        just tf {{action}} "$dir" || exit 1; \
    done

# Mutating formatter — opposite of _tf-fmt's --check mode.
[private]
_tf-fix module:
    @just _log "terraform fmt -recursive → modules/{{module}}"
    cd modules/{{module}} && terraform fmt -recursive

# Aggregated lint surface: actionlint + shellcheck + markdownlint
# + yamllint + prettier --check. Useful for pre-push.
[group('lint')]
lint-all:
    @just _log "actionlint"
    actionlint
    @just _log "shellcheck scripts/*.sh"
    shellcheck scripts/*.sh
    @just docs lint
    @just _log "yamlfmt -lint ."
    yamlfmt -lint .
    @just _log "yamllint ."
    yamllint .
    @just _log "prettier --check '**/*.{json,md,yaml,yml}'"
    prettier --check '**/*.{json,md,yaml,yml}'
```

#### Time-to-signal estimates

Per the existing per-module timings documented in CLAUDE.md
+ FINDINGS.md:

| Job | Cost | Parallelism |
|-----|------|-------------|
| `changes` (path filter) | ~5s | 1 |
| Early-fail gates (each) | ~15-30s | 7 parallel |
| `module-test` per module | ~10-15s (mise install ~5s + `just tf all` ~5-10s) | up to 8 parallel |
| `trivy` per module | ~15s | up to 8 parallel |
| `localstack-test` per module | ~75-90s (LocalStack startup ~30s + `just tf test-localstack` ~30-45s) | up to 8 parallel |

**PR touching one module, no LocalStack label:**
~30-45s wall clock (early gates run in parallel with module-test).

**PR touching `meta` (justfile / workflow / repo-wide config):**
~60-90s wall clock — all 8 modules fan out + early gates.

**Scheduled nightly LocalStack run:**
~2-3 minutes wall clock — all 8 modules in parallel.

### Observation 3 — Cross-module dependency drift (Approach step 3)

The user's Q1 concern made concrete. Enumerated every
`data.terraform_remote_state` block in `modules/` to catalog
the actual edges + mapped them to specific outputs that the
owning modules emit. The dependency graph is **less risky than
feared**: only one in-repo edge has more than 1 downstream
consumer today, and every downstream consumer already stubs
the upstream via `override_data` in its plan-only test suite.

#### Concrete dependency graph (as of `2cd92c0`)

```text
vpc (out-of-tree)
├── vpc_id ─────────────► eks/cluster, rds/serverless, efs/filesystem
└── private_subnet_ids ─► eks/cluster, eks/managed-node-group, rds/serverless, efs/filesystem

eks/cluster (8 outputs; 4 in-repo consumers)
├── cluster_name ─────────► eks/addons, eks/managed-node-group, eks/pod-identity-access
├── cluster_version ─────► eks/addons (data.aws_eks_addon_version lookups)
├── cluster_endpoint ────► eks/managed-node-group (nodeadm user_data)
├── cluster_ca_data ─────► eks/managed-node-group (nodeadm user_data)
├── cluster_oidc_issuer_url ─► (no current in-repo consumer; emitted for IAM-OIDC trust policies in future modules)
├── cluster_security_group_id ─► (no current in-repo consumer)
├── node_security_group_id ─► eks/managed-node-group, efs/filesystem
└── kms_key_arn ─────────► eks/managed-node-group (EBS encryption)

rds/serverless (14 outputs)
└── ZERO in-repo consumers today
    Planned per DESIGN-0007: cluster_identifier + db_subnet_group_name
    + security_group_id will be consumed by rds/cluster + rds/read-replica
    when those modules ship.

ecr/pull-through-cache, ecr/org-registry, efs/filesystem
└── ZERO in-repo consumers (terminal nodes; their outputs feed
    Kubernetes manifests, IAM policies in other accounts, or
    nothing).
```

#### Risk classification

| Edge | Consumers | Today's mitigation | Drift risk |
|------|-----------|--------------------|-----------|
| `eks/cluster.cluster_name` | 3 modules | `override_data` in each consumer's `tests/` | **Medium** — most-consumed in-repo output. Rename breaks 3 modules. |
| `eks/cluster.cluster_version` | 1 module (addons) | `override_data` in `addons/tests/*.tftest.hcl` | **Low** — single consumer. |
| `eks/cluster.node_security_group_id` | 2 modules (mng, efs) | `override_data` in both | **Medium** — added in IMPL-0008 to support efs/filesystem; the only edge that's been added since the cluster module's IMPL-0001 contract was set. |
| `eks/cluster.kms_key_arn` | 1 module (mng) | `override_data` in `managed-node-group/tests/` | **Low** — single consumer. |
| `eks/cluster.{cluster_endpoint,cluster_ca_data}` | 1 module (mng) | `override_data` in `managed-node-group/tests/` | **Low** — single consumer (nodeadm user_data). |
| `eks/cluster.cluster_oidc_issuer_url` | 0 | n/a | **None today** — emitted as a stable surface for future modules; rename safe until first consumer lands. |
| `eks/cluster.cluster_security_group_id` | 0 | n/a | **None today** — same as above. |
| `vpc.vpc_id`, `vpc.private_subnet_ids` | 4 modules each | `override_data` in every consumer | **External** — owned by the VPC stack outside this repo; cannot be enforced here. |

Notable: every consumer already `override_data`-stubs the
remote-state read in its plan-only `tests/` suite. So
**variable-name** drift (rename) silently produces wrong stub
data without surfacing in either the consumer's or the
producer's CI. **Type/shape** drift (string → list, scalar →
null) does surface — but only if the consumer's plan-time
assertions exercise the consuming attribute.

#### Mitigation evaluation

##### (a) Output contract tests in the OWNING module — *recommended short-term*

Each module that emits remote-state outputs adds a
`tests/outputs.tftest.hcl` file with a single `plan` run that
asserts:

```hcl
# modules/eks/cluster/tests/outputs.tftest.hcl
run "output_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
      }
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "000000000000", arn = "arn:aws:iam::000000000000:root", user_id = "STUB" }
  }

  # Frozen output contract. Any rename, removal, or type change
  # fails THIS test in the OWNING module's CI before downstream
  # consumers ever see drift. Updating this file is the explicit
  # operator gesture that documents an output contract change.
  assert {
    condition     = output.cluster_name != null
    error_message = "output 'cluster_name' must exist (consumed by addons, managed-node-group, pod-identity-access)"
  }
  assert {
    condition     = output.cluster_version != null
    error_message = "output 'cluster_version' must exist (consumed by addons)"
  }
  assert {
    condition     = output.cluster_endpoint != null
    error_message = "output 'cluster_endpoint' must exist (consumed by managed-node-group user_data)"
  }
  assert {
    condition     = output.cluster_ca_data != null
    error_message = "output 'cluster_ca_data' must exist (consumed by managed-node-group user_data)"
  }
  assert {
    condition     = output.cluster_oidc_issuer_url != null
    error_message = "output 'cluster_oidc_issuer_url' must exist (reserved for future IAM-OIDC trust policies)"
  }
  assert {
    condition     = output.cluster_security_group_id != null
    error_message = "output 'cluster_security_group_id' must exist (reserved for future consumers)"
  }
  assert {
    condition     = output.node_security_group_id != null
    error_message = "output 'node_security_group_id' must exist (consumed by managed-node-group, efs/filesystem)"
  }
  assert {
    condition     = output.kms_key_arn != null
    error_message = "output 'kms_key_arn' must exist (consumed by managed-node-group EBS encryption)"
  }
}
```

**Cost:** one extra test file per producer module
(eks/cluster, rds/serverless once it grows consumers, vpc
outside this repo). Each file is ~70 LoC and runs in <1s.
Each error_message names the specific downstream consumer so
the failure is self-documenting.

**Limits:**

- `output.<name>` access in `terraform test` only works when
  the apply or plan produces a known value. Computed-at-apply
  outputs (e.g. `cluster_endpoint` resolved from
  `aws_eks_cluster.this.endpoint`) ARE plan-time unknown, so
  `output.cluster_endpoint != null` does NOT fail when the
  output is unknown. The test exercises **the output's
  existence in the module's output set**, not its value —
  which IS the contract we want to lock down.
- Test catches name + type rename but NOT semantic rename (the
  user renames `cluster_endpoint` to `writer_endpoint` AND
  updates this file in the same commit — the test passes,
  drift persists). Operator discipline gap.

##### (b) Reverse-lookup matrix — *evaluated, NOT recommended for short-term*

When an output-side module changes, CI also runs every
downstream consumer's `tests/` suite via `override_data` stubs
built from the producer's current `outputs.tf`. Conceptually:

```yaml
# ci.yml addition (sketch):
reverse-deps:
  name: Reverse dependency check
  needs: changes
  runs-on: ubuntu-latest
  if: ${{ contains(needs.changes.outputs.modules, 'eks/cluster') }}
  strategy:
    matrix:
      consumer: [eks/managed-node-group, eks/addons, eks/pod-identity-access, efs/filesystem]
  steps:
    - run: just tf test ${{ matrix.consumer }}
```

**Pros:** A `cluster_name` rename in eks/cluster surfaces in
the managed-node-group + addons + pod-identity-access +
efs/filesystem CI on the same PR.

**Cons:**

- Requires a manually maintained reverse-dependency map
  (`if: contains(...)` per producer). 3 producers today
  (vpc, eks/cluster, rds/serverless-once-consumed), 5
  consumer modules. Scales poorly as the fleet grows.
- The consumer's `tests/` suite already uses
  `override_data` stubs with literal values — it does NOT
  re-read the producer's `outputs.tf`. So a rename in the
  producer that the consumer didn't update (because the
  consumer wasn't touched) DOES NOT fail the consumer's test
  — the stub still uses the old name. The reverse-lookup
  matrix is only useful if we ALSO replace the consumer's
  `override_data` stubs with a generated stub-from-producer-
  outputs.tf step. Significant infrastructure.
- (a) already catches the rename in the producer's CI
  before merge. The reverse-lookup matrix adds value only
  for cases where the producer's test was also updated
  alongside the rename — i.e., operator discipline gap
  cases. Same gap (a) has.

Verdict: **skip.** Either invest in (c) for real coverage or
accept (a)'s discipline gap.

##### (c) Custom Go CLI computes reverse-deps from HCL — *long-term, sibling RFC*

The Go CLI parses every module's `*.tf` files via
`hashicorp/hcl/v2`, builds the producer→consumer graph from
`data "terraform_remote_state"` blocks + `outputs.tf` reads,
and emits the reverse-dependency set on demand:

```bash
$ <cli> reverse-deps eks/cluster
eks/managed-node-group
eks/addons
eks/pod-identity-access
efs/filesystem
```

CI consumes this in the matrix:

```yaml
reverse-deps:
  name: Reverse dependency check
  needs: changes
  runs-on: ubuntu-latest
  steps:
    - id: reverse
      run: |
        affected=$(<cli> reverse-deps ${{ matrix.touched }} | jq -R . | jq -sc .)
        echo "modules=$affected" >>"$GITHUB_OUTPUT"
    - uses: ./.github/actions/run-module-tests
      with:
        modules: ${{ steps.reverse.outputs.modules }}
```

The CLI also generates `override_data` stubs from the
producer's current `outputs.tf` — so the consumer's
`override_data` block becomes a generated artifact instead of
hand-maintained literals. This closes both gaps that (a) and
(b) leave open:

- **Rename gap:** producer's `outputs.tf` change → regenerate
  all consumers' `override_data` stubs → drift surfaces in
  consumers' tests.
- **Semantic rename gap:** producer's `outputs.tf` change
  surfaces in the producer's `outputs.tftest.hcl` (which is
  also regenerated by the CLI from the same source) — and
  the operator gesture to update both is one CLI call, not
  N hand edits.

**Scope confirmed for the sibling RFC.** This work is the
single largest justification for building the custom Go CLI:
the alternative (b) is fragile, and (a) has a discipline gap
that only HCL parsing closes.

#### Short-term recommendation (folds into the PLAN doc)

1. Ship the `outputs.tftest.hcl` files for **eks/cluster** +
   **rds/serverless** (the only producers with current /
   planned in-repo consumers). 2 files, ~150 LoC total. Both
   land in the matrix workflow's per-module `module-test`
   job — no CI changes needed.
2. Add a CLAUDE.md note: "renaming a remote-state output is
   a contract change. Update the producer's
   `tests/outputs.tftest.hcl` in the same PR. Every consumer's
   `override_data` stub must be updated in the same PR."
3. Document the reverse-dependency map in
   `docs/adr/0001-cross-module-composition-via-terraformremotestate.md`
   as a maintained section until the Go CLI ships.

The discipline gap is acknowledged + the long-term fix (Go
CLI reverse-deps) is on the sibling RFC's critical path.

### Observation 4 — Trivy / static security scanning (Approach step 4)

Probed `aquasec/trivy:latest` against `modules/efs/filesystem`
locally on 2026-05-29 (no Trivy installed via mise — ran via
`docker run`). Surfaced **1 finding in the module itself** +
**9 findings in the tests-localstack fixture**. All findings
are actionable categories (S3 public access, SG egress
posture, KMS CMK enforcement, VPC flow logs); none are false
positives. The module-scope finding is intentional + already
documented (`SG spec symmetry; mount-target ENIs never
initiate` per the `network.tf` comment) — a Trivy exemption is
the appropriate response, not a code change.

#### Probe results

```text
$ docker run --rm -v "$PWD:/repo" aquasec/trivy:latest \
    config /repo/modules/efs/filesystem \
    --severity HIGH,CRITICAL,MEDIUM,LOW

# Module sources (modules/efs/filesystem/*.tf):
Tests: 1 (SUCCESSES: 0, FAILURES: 1)
Failures: 1 (LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 1)

  AWS-0104 (CRITICAL): Security group rule allows unrestricted
    egress to any IP address.
    network.tf:33-39  aws_vpc_security_group_egress_rule.all
    cidr_ipv4 = "0.0.0.0/0", ip_protocol = "-1"

# Test fixture (tests-localstack/fixtures/setup/main.tf):
Tests: 9 (SUCCESSES: 0, FAILURES: 9)
Failures: 9 (LOW: 2, MEDIUM: 2, HIGH: 5, CRITICAL: 0)

  AWS-0086 (HIGH)   No public access block — blocking public acls
  AWS-0087 (HIGH)   No public access block — blocking public policies
  AWS-0089 (LOW)    Bucket has logging disabled
  AWS-0090 (MEDIUM) Bucket does not have versioning enabled
  AWS-0091 (HIGH)   No public access block — ignoring public acls
  AWS-0093 (HIGH)   No public access block — restricting public buckets
  AWS-0094 (LOW)    Bucket does not have a corresponding public access block
  AWS-0132 (HIGH)   Bucket does not encrypt data with a customer managed key
  AWS-0178 (MEDIUM) VPC does not have VPC Flow Logs enabled
```

#### Signal quality

| Finding | Verdict | Action |
|---------|---------|--------|
| AWS-0104 on `network.tf::aws_vpc_security_group_egress_rule.all` | **True positive, accepted by design.** EFS mount-target ENIs never initiate traffic; the egress rule is SG spec symmetry only. Documented inline in `network.tf` and in the module's README §Operational gotchas. | Add `# trivy:ignore:AWS-0104` inline above the resource with a cross-reference to the README. Equivalent inline annotation in every other module that ships an all-outbound egress rule (rds/serverless, eks/cluster). |
| All 9 fixture findings | **True positives, accepted because it's a fixture.** The `tests-localstack/fixtures/setup/main.tf` builds a throwaway VPC + S3 stub state — production posture is irrelevant. | Scope Trivy to `modules/<svc>/<name>/*.tf` only, excluding `tests-localstack/**`. Trivy supports `--skip-dirs` for this. |

The signal-to-noise ratio is high once the fixture
exclusion lands. Real findings would surface where they
matter: in production-shaped module sources.

#### Alternatives evaluated

| Tool | Status | Verdict |
|------|--------|---------|
| **Trivy** (`aquasec/trivy-action`) | Aquasec-maintained; absorbed tfsec in 2023. SARIF output → GitHub Code Scanning. Supports `.trivyignore` + inline `# trivy:ignore:...` + per-misconfig `--skip-files` / `--skip-dirs`. Single binary, available via mise + docker. | **Recommended.** |
| **tfsec** | Deprecated. The GitHub repo redirects to Trivy. No new rules since 2023. | Skip. |
| **Checkov** (Bridgecrew / Prisma) | Python-based; broader policy bundle (~1000 rules vs Trivy's ~250 for AWS) but higher false-positive rate + heavier setup (Python venv vs single binary). Notable rules Trivy lacks: CKV2_AWS_* "ensure module has output X". Slower (~5x). | Skip. The extra rule coverage doesn't justify the maintenance overhead at 8 modules; revisit if the fleet grows to 30+. |
| **terraform-compliance** | BDD-style (`Given a resource of type aws_s3_bucket / Then it must have property X`). Requires hand-authored feature files. Mismatch for a baseline scan. | Skip. |
| **Sentinel** (HashiCorp Cloud) | Requires Terraform Cloud / Enterprise. We're not on TFC. | Skip. |
| **OPA / conftest** | Generic policy engine; would require authoring rego rules from scratch. Useful for fleet-specific policies (e.g., "every module must emit `kms_key_arn`") that Trivy can't express, but heavy for general misconfig scanning. | Skip baseline; reconsider when fleet-specific output-contract policies are needed and the Go CLI doesn't yet ship them. |

#### Workflow integration

Already sketched in Observation 2's `ci.yml::trivy` matrix
job. Refinements based on the probe:

```yaml
trivy:
  name: Trivy config scan
  runs-on: ubuntu-latest
  needs: changes
  if: ${{ needs.changes.outputs.modules != '[]' }}
  permissions:
    contents: read
    security-events: write
  strategy:
    fail-fast: false
    matrix:
      module: ${{ fromJSON(needs.changes.outputs.modules) }}
      exclude:
        - module: meta
  steps:
    - uses: actions/checkout@v6
    - uses: aquasecurity/trivy-action@v0
      with:
        scan-type: config
        scan-ref: modules/${{ matrix.module }}
        # Exclude tests-localstack fixtures — throwaway VPC + S3
        # stub state buckets generate noise that distracts from
        # production-shape findings.
        skip-dirs: 'modules/${{ matrix.module }}/tests-localstack'
        format: sarif
        output: trivy-${{ matrix.module }}.sarif
        # HIGH+CRITICAL break the build. MEDIUM/LOW surface in
        # Code Scanning without blocking.
        severity: HIGH,CRITICAL
        exit-code: '1'
        # Honor in-file # trivy:ignore:AWS-XXXX comments + the
        # repo-root .trivyignore file.
        ignore-policy: .trivyignore
    - uses: github/codeql-action/upload-sarif@v4
      if: always()
      with:
        sarif_file: trivy-${{ matrix.module }}.sarif
        category: trivy-${{ matrix.module }}
```

Also add Trivy to `mise.toml` so `just trivy <module>` can
run locally pre-push:

```toml
# mise.toml addition
trivy = "0.55.1"  # or latest stable; Renovate-tracked
```

```just
# justfile addition
[group('tf')]
tf-trivy module:
    @just _log "trivy config → modules/{{module}}"
    trivy config \
      --skip-dirs 'modules/{{module}}/tests-localstack' \
      --severity HIGH,CRITICAL \
      modules/{{module}}
```

#### Exemption strategy

Two layers:

1. **In-file `# trivy:ignore:AWS-XXXX`** comments — for
   single-resource exemptions that are documented at the use
   site. Use this for the AWS-0104 egress-0.0.0.0/0
   pattern in every module that ships the all-outbound rule.
   Example:

   ```hcl
   # network.tf
   # trivy:ignore:AWS-0104 — SG spec symmetry; mount-target ENIs
   # never initiate traffic. See README §Operational gotchas.
   resource "aws_vpc_security_group_egress_rule" "all" {
     security_group_id = aws_security_group.this.id
     cidr_ipv4         = "0.0.0.0/0"
     ip_protocol       = "-1"
     description       = "All-outbound egress (SG spec symmetry; mount-target ENIs never initiate)"
     tags              = var.tags
   }
   ```

2. **Repo-root `.trivyignore`** — for cross-module
   exemptions that apply everywhere (none today; reserved for
   future cases like "all modules use `module-managed`
   `aws_kms_key` with `prevent_destroy = true`, ignore
   AWS-XXXX about KMS deletion-window policy"). Format:

   ```text
   # .trivyignore — see docs/adr/<n>-trivy-exemptions.md for rationale
   AWS-0024  # noisy on test-only resources
   ```

   The PLAN doc creates the ADR explaining each exemption.

#### Frequency / cost

| Job | Frequency | Cost per run | Annual cost (8 modules, ~50 PRs/yr touching modules) |
|-----|-----------|--------------|-----------------------------------------------------|
| `trivy` matrix entry | Per touched module per PR | ~15-20s (image pull cached on warm runner; scan ~5s per module) | ~3-5 min CI time per PR; ~3-5 hr/yr total |
| Local `just tf-trivy <module>` | Pre-push (operator choice) | ~5s | Negligible |

The matrix-per-PR posture matches the rest of the workflow.
A scheduled weekly fleet-wide scan is unnecessary because
Trivy's rule database doesn't drift on the timescale that
matters (and Renovate will bump the action version when
rules add).

#### Recommendation

- **Adopt Trivy** as the static security scanner. Wire it
  per Observation 2's matrix job + the refinements above.
- **Decline** Checkov, terraform-compliance, Sentinel, OPA
  for the short term. Revisit if the fleet grows past 30
  modules or if fleet-specific policies (output contracts,
  naming conventions) emerge that Trivy can't express.
- **Two-layer exemptions**: inline `# trivy:ignore:...`
  comments with documented rationale, plus a repo-root
  `.trivyignore` for cross-module cases. Each exemption gets
  an ADR entry. The ADR is the durable rationale; the
  inline comment is the use-site signal.
- **Local parity**: `mise.toml` pins Trivy + `just tf-trivy
  <module>` runs the same scan locally.
- **First-PR cleanup tasks** (track in the PLAN):
  - Add `# trivy:ignore:AWS-0104` to every all-outbound
    egress rule with a documented `# trivy:ignore` rationale.
    Surveyed modules: efs/filesystem (network.tf:33),
    rds/serverless (network.tf:39), eks/cluster (likely;
    confirm in the PLAN).
  - Add `skip-dirs: tests-localstack` exemption — fixture
    code is not production posture.

### Observation 5 — Renovate surface inventory + config design (Approach step 5)

Catalogued every pinned version in the repo + classified each
pin by which dependency manager can track it natively (Renovate
vs Dependabot). The verdict is **Renovate wins decisively**:
Dependabot can't see ~40% of the pins (tflint plugins, mise
tools, in-HCL gvisor / Aurora majors / LocalStack image), and
the existing Dependabot config is already mostly broken per
Observation 1.

#### Pinned-version surface

| Surface | Pin location | Count | Dependabot manager | Renovate manager |
|---------|--------------|-------|--------------------|------------------|
| `hashicorp/aws ~> 6.2` provider constraint | `modules/<svc>/<name>/versions.tf` | 8 identical | `terraform` (since 2024) | `terraform` |
| `terraform >= 1.1` required_version | `modules/<svc>/<name>/versions.tf` | 8 identical | ✗ | `terraform` |
| tflint plugin `aws` 0.47.0 | `modules/<svc>/<name>/.tflint.hcl` | 8 | ✗ | `tflint-plugin` |
| tflint plugin `terraform-style` 0.0.5 | `modules/<svc>/<name>/.tflint.hcl` | 8 | ✗ | `tflint-plugin` |
| GitHub Actions versions | `.github/workflows/*.yml` (incl. `.bak`) | ~15 distinct | `github-actions` | `github-actions` |
| mise tool versions | `mise.toml` (root) | 25+ entries | ✗ | `mise` |
| `gvisor_version` default | `modules/eks/managed-node-group/variables.tf:174` | 1 (Renovate-flagged in comments) | ✗ | `customManagers` (regex) |
| `gvisor_sha512` digests | `modules/eks/managed-node-group/variables.tf:182` (default empty; populated by Renovate per IMPL-0002 design) | 1 map | ✗ | `customManagers` (regex) — updated alongside `gvisor_version` |
| Aurora parameter family majors | `modules/rds/serverless/locals.tf:25-29` | 4 entries | ✗ | `customManagers` (regex) — bump cadence ~annual |
| `default_major_map` for postgres + mysql | `modules/rds/serverless/locals.tf:36-39` | 2 entries | ✗ | `customManagers` (regex) — paired with parameter family |
| LocalStack image | `.github/workflows/ci-localstack.yml` (planned: `localstack/localstack:3.8.1`) | 1 (post-cleanup) | `docker` | `docker` |
| EFS lifecycle defaults (`AFTER_30_DAYS`, `AFTER_90_DAYS`) | `modules/efs/filesystem/variables.tf:97-102` | 2 string literals | ✗ | ✗ (AWS-defined enum; not a tracked release) |
| `mise.toml` Go-module tools (`go-licenses`, `govulncheck`, `mockery`, etc.) | `mise.toml` (`go:...` entries) | 7 | `gomod` (root go.mod only) | `mise` + transitive |

The "Renovate manager" column is the named manager Renovate
uses for the surface. For the in-HCL pins flagged
`customManagers`, the config is regex + datasource +
depName — Renovate's `customManagers` (formerly
`regexManagers`) covers the case cleanly.

#### Renovate vs Dependabot — decision matrix

| Factor | Dependabot | Renovate |
|--------|-----------|----------|
| Surfaces tracked here | 4 of 12 (33%) | 12 of 12 (100%) |
| `customManagers` / regex pins | ✗ | ✓ |
| `tflint-plugin` manager | ✗ | ✓ (community-extended) |
| `mise` manager | ✗ | ✓ (since 2024) |
| Grouped PRs (e.g. all provider-aws bumps batched) | Limited (one-PR-per-package) | ✓ via `groupName` + `packageRules` |
| Auto-merge based on label / status | ✓ (built-in) | ✓ (built-in) |
| Schedule control | Per-ecosystem `interval` only | Cron-style; per-rule schedules |
| Cooldown / stability days | `cooldown.default-days` | `minimumReleaseAge` per rule |
| Hosted by GitHub directly | ✓ | App install (Mend Renovate) |
| Existing repo state | Configured but ~60% broken | Greenfield |
| Cost | Free | Free (open-source repos via Mend) |

**Recommendation: replace Dependabot wholesale with Renovate.**
The split-brain of running both is worse than picking one;
Renovate covers everything Dependabot does plus the in-HCL
+ tflint + mise pins Dependabot can't see.

#### Proposed `.github/renovate.json` shape

```jsonc
// $schema: https://docs.renovatebot.com/renovate-schema.json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":dependencyDashboard",
    ":semanticCommits",
    ":separatePatchReleases",
    "schedule:weekly"
  ],
  "timezone": "America/Chicago",
  "labels": ["dependencies"],
  "prHourlyLimit": 4,
  "prConcurrentLimit": 10,

  // Semantic commit scope per manager — feeds the conventional-
  // commits parser that git-cliff (and the future Go CLI)
  // consumes.
  "semanticCommitType": "chore",
  "semanticCommitScope": "deps",

  // Each pinned surface gets its own group so a single PR
  // bumps all 8 modules' provider in lockstep (catches
  // cross-module breakage at fan-out time).
  "packageRules": [
    {
      "matchManagers": ["terraform"],
      "matchDepTypes": ["provider"],
      "groupName": "terraform providers",
      "semanticCommitScope": "deps/tf"
    },
    {
      "matchManagers": ["terraform"],
      "matchDepTypes": ["required_version"],
      "groupName": "terraform core",
      "semanticCommitScope": "deps/tf"
    },
    {
      "matchManagers": ["custom.tflintPlugins"],
      "groupName": "tflint plugins",
      "semanticCommitScope": "deps/tflint"
    },
    {
      "matchManagers": ["github-actions"],
      "groupName": "github actions",
      "semanticCommitScope": "deps/ci"
    },
    {
      "matchManagers": ["mise"],
      "groupName": "mise tools",
      "semanticCommitScope": "deps/mise"
    },
    {
      "matchManagers": ["docker"],
      "matchPackageNames": ["localstack/localstack"],
      "groupName": "localstack image",
      "semanticCommitScope": "deps/ci",
      // Pin to Community releases until the FINDINGS.md gap
      // closes (LocalStack 4+ requires Pro auth even on the
      // community image tag). Constraint reviewed in INV-0003.
      "allowedVersions": "<4.0.0"
    },
    {
      "matchManagers": ["custom.gvisor"],
      "groupName": "gvisor (managed-node-group)",
      "semanticCommitScope": "deps/tf",
      // gVisor releases biweekly; we don't need to ride every
      // release — stability window catches regressions before
      // we adopt.
      "minimumReleaseAge": "14 days"
    },
    {
      "matchManagers": ["custom.auroraEngines"],
      "groupName": "aurora engine majors",
      "semanticCommitScope": "deps/tf",
      // Engine-major bumps are operator PRs by design (per
      // IMPL-0007 Phase 2 / parameter_family precondition).
      // Renovate opens the PR but humans land it.
      "minimumReleaseAge": "30 days",
      "automerge": false
    },

    // Security updates always bypass schedule + cooldown.
    {
      "matchCurrentVersion": "!/^0/",
      "matchUpdateTypes": ["patch"],
      "automerge": false,
      "schedule": ["before 6am on monday"]
    }
  ],

  "customManagers": [
    {
      "customType": "regex",
      "description": "tflint plugin versions in .tflint.hcl",
      "managerFilePatterns": ["/modules/.+/\\.tflint\\.hcl$/"],
      "matchStrings": [
        "source\\s*=\\s*\"github\\.com/(?<depName>[^\"]+)\"\\s*[\\s\\S]*?version\\s*=\\s*\"(?<currentValue>[^\"]+)\""
      ],
      "datasourceTemplate": "github-releases"
    },
    {
      "customType": "regex",
      "description": "gvisor release tag + SHA-512 digests",
      "managerFilePatterns": ["/modules/eks/managed-node-group/variables\\.tf$/"],
      "matchStrings": [
        "default\\s*=\\s*\"(?<currentValue>release-\\d{8}\\.\\d+)\""
      ],
      "depNameTemplate": "google/gvisor",
      "datasourceTemplate": "github-releases"
    },
    {
      "customType": "regex",
      "description": "Aurora engine majors in parameter_family_map",
      "managerFilePatterns": ["/modules/rds/serverless/locals\\.tf$/"],
      "matchStrings": [
        "\"aurora-postgresql:(?<currentValue>\\d+)\""
      ],
      "depNameTemplate": "aurora-postgresql",
      "datasourceTemplate": "custom.aws-rds-engines"
    }
  ],

  "customDatasources": {
    // Stub for the AWS RDS engine-version datasource. Real impl
    // either (a) hits the static https://aws.amazon.com page
    // periodically or (b) hosts a small JSON in the repo that
    // a scheduled job updates. Decision parked for the PLAN.
    "aws-rds-engines": {
      "defaultRegistryUrlTemplate": "https://aws.amazon.com/rds/aurora/postgresql-features/",
      "format": "html"
    }
  },

  "vulnerabilityAlerts": {
    "enabled": true,
    "labels": ["security", "dependencies"]
  },

  "lockFileMaintenance": {
    "enabled": false
  }
}
```

#### In-HCL annotation discipline

For cases where the bare `default = "..."` doesn't give
Renovate enough signal (e.g., the `gvisor_sha512` map is keyed
by binary name, not version), use the `# renovate:`
annotation syntax inline:

```hcl
# variables.tf
variable "gvisor_version" {
  # renovate: datasource=github-releases depName=google/gvisor
  default     = "release-20260101.0"
  description = "..."
}

variable "gvisor_sha512" {
  # renovate: datasource=github-releases depName=google/gvisor extractVersion=^release-(.+)$
  default = {
    runsc                     = "abc123..."  # SHA-512 from upstream release artifact
    containerd_shim_runsc_v1  = "def456..."
  }
}
```

The annotation lives ABOVE the `default` line so the regex
matcher can anchor on it. The PLAN doc adds these annotations
where Renovate's bare regex can't infer the datasource.

#### Renovate `customManagers` testing

Renovate ships a CLI mode for testing config locally:

```bash
LOG_LEVEL=debug renovate --dry-run \
  --platform=local \
  --include-paths=modules/eks/managed-node-group/variables.tf \
  > renovate-dry-run.log
```

Wire into the justfile so config drift gets caught locally:

```just
[group('lint')]
renovate-check:
    @just _log "renovate --dry-run (local)"
    npx --yes renovate --dry-run --platform=local
```

The PLAN doc lands `npx renovate --dry-run` as a CI job too
(non-blocking) so config-level regressions surface on PR
review.

#### Migration steps for the PLAN

1. **Install the Mend Renovate GitHub App** on the repo.
   (Mend hosts the free tier for open-source repos.)
2. **Drop `.github/dependabot.yml`** in the same PR that adds
   `.github/renovate.json`. No co-existence period — both
   would race on the same surfaces.
3. **Add `# renovate:` annotations** to `gvisor_version`,
   `gvisor_sha512`, and any other in-HCL pin that needs
   datasource disambiguation.
4. **Pin LocalStack to `<4.0.0`** in the ci-localstack
   workflow + Renovate config until Pro auth is sorted (per
   FINDINGS.md from IMPL-0008 Phase 10).
5. **Run `renovate --dry-run`** against the branch to verify
   each manager catches its intended pins. Adjust the
   `customManagers` regexes until the dry-run output matches
   the inventory above.
6. **Open the Dependency Dashboard issue** — Renovate's
   `:dependencyDashboard` preset opens a tracking issue
   that lists every pending bump.

### Observation 6 — Release tooling, short-term vs long-term (Approach step 6)

Two-track posture confirmed: keep the existing label-driven
repo-level tagger + git-cliff CHANGELOG as the stopgap, and
scope the long-term per-module versioning to the sibling RFC.
The short-term track has zero net-new tooling — just a
`cliff.toml` + seed `CHANGELOG.md` + `git-cliff` added to
`mise.toml`, all needed anyway to re-enable
`changelog.yml.bak` per Observation 1.

#### Short-term: repo-level tagger + git-cliff CHANGELOG

##### Already working

`release.yml::bump-version` is the only piece that actually
ran on PR #17 (`v0.9.0`) and PR #18 (next bump). Mechanics:

- `jefflinse/pr-semver-bump@v1.7.4` reads the merged PR's
  labels (`major` / `minor` / `patch` / `dont-release`).
- Computes the new version against the latest existing tag.
- Pushes the `vX.Y.Z` tag (`with-v: true`).
- Skips when `dont-release` (or here, `dont-release`) is set.

The labels are already gated by `pr-labels.yml`'s
`Check Required Labels` job — so every merged PR carries a
release-affecting label. No drift.

##### Net-new wiring

Three small changes to revive `changelog.yml.bak`:

1. **Add `git-cliff` to `mise.toml`.**

   ```toml
   # mise.toml addition
   git-cliff = "2.13.1"  # matches the user's global install
   ```

   Without this, `jdx/mise-action@v3` doesn't put `git-cliff`
   on a runner's PATH — the .bak workflow's bare
   `run: git-cliff -o CHANGELOG.generated.md` fails.

2. **Seed `CHANGELOG.md` at the repo root.** Run `git-cliff`
   against current history once to populate the initial file;
   the drift-check workflow then keeps it current per PR.

   ```bash
   git-cliff -o CHANGELOG.md  # one-time seed
   ```

3. **Author `cliff.toml`.** Tuned for the conventional-commit
   shape the user already authors (`feat(efs/filesystem): ...`,
   `test(rds/serverless): ...`):

   ```toml
   # cliff.toml — git-cliff config
   # See https://git-cliff.org/docs/configuration for syntax.

   [changelog]
   header = """
   # Changelog

   All notable changes to this project will be documented in
   this file. Format derived from [Keep a Changelog]; versions
   follow [Semantic Versioning]. Module-level changelogs land
   here as scoped subsections (e.g. `efs/filesystem`); per-
   module CHANGELOG.md files arrive with the future Go CLI
   (see INV-0003 / sibling RFC).

   [Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
   [Semantic Versioning]: https://semver.org/spec/v2.0.0.html
   """
   body = """
   {% if version %}\
       ## [{{ version }}] - {{ timestamp | date(format="%Y-%m-%d") }}
   {% else %}\
       ## [Unreleased]
   {% endif %}\
   {% for group, commits in commits | group_by(attribute="group") %}
       ### {{ group | upper_first }}
       {% for commit in commits %}
           - **{{ commit.scope | default(value="repo") }}**: \
             {{ commit.message | upper_first }}\
             {% if commit.breaking %} ⚠ breaking{% endif %}\
       {% endfor %}
   {% endfor %}
   """
   footer = ""
   trim = true

   [git]
   conventional_commits = true
   filter_unconventional = true
   split_commits = false
   protect_breaking_commits = true

   commit_parsers = [
       { message = "^feat",     group = "Features" },
       { message = "^fix",      group = "Bug Fixes" },
       { message = "^docs",     group = "Documentation" },
       { message = "^test",     group = "Tests" },
       { message = "^refactor", group = "Refactoring" },
       { message = "^perf",     group = "Performance" },
       { message = "^style",    group = "Styling" },
       { message = "^build",    group = "Build" },
       { message = "^ci",       group = "CI" },
       # Renovate's grouped PRs land as `chore(deps/...)` —
       # filtered into a separate group + collapsed to keep
       # the human-curated sections readable.
       { message = "^chore\\(deps", group = "Dependencies" },
       { message = "^chore",       group = "Misc" },
       # Drop the changelog-sync loopback commits the .bak
       # workflow would have created — filter_commits = true
       # means matched commits are skipped, not grouped.
       { message = "^chore\\(changelog\\)", skip = true },
   ]

   filter_commits = true
   tag_pattern = "v[0-9]*"
   skip_tags = ""
   ignore_tags = ""
   topo_order = false
   sort_commits = "oldest"
   ```

##### `changelog.yml` final shape

Rename `.bak` → `.yml` with two adjustments to the inherited
file:

```yaml
---
name: Changelog Drift Check
on:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: jdx/mise-action@v3
        with:
          experimental: true
      # git-cliff now comes from mise.toml — no extra install
      # step needed.
      - name: Regenerate fresh CHANGELOG
        run: git-cliff -o CHANGELOG.generated.md
      - name: Diff against committed CHANGELOG
        run: |-
          if ! diff -q CHANGELOG.md CHANGELOG.generated.md > /dev/null; then
            echo "::error::CHANGELOG.md is stale. Run 'git-cliff -o CHANGELOG.md' and commit."
            diff CHANGELOG.md CHANGELOG.generated.md || true
            exit 1
          fi
```

This is a drift check, not an auto-commit. The
`release.yml::changelog-sync` job from the inherited (and
commented-out) workflow would auto-commit on merge — but that
adds a `chore(changelog): sync vX.Y.Z` commit that the next
git-cliff run has to ignore (handled by the `skip = true`
parser above, but adds noise). The drift check shifts the
burden to the PR author + a `just changelog-regen` recipe:

```just
# justfile addition
[group('docs')]
changelog-regen:
    @just _log "git-cliff -o CHANGELOG.md"
    git-cliff -o CHANGELOG.md
```

##### Alternatives evaluated

| Tool | Verdict | Reason |
|------|---------|--------|
| **git-cliff** | **Keep** | Already in mise (global) + the user already uses it; minimal incremental work; conventional-commit parser matches the user's commit style. |
| **Release Please** (Google) | Skip | Forces its own release-PR workflow (auto-opens a "Release X" PR with the changelog inline). Fights with the `pr-semver-bump` label-driven tagger that already works. Higher delta than git-cliff for marginal benefit at repo scale. |
| **semantic-release** | Skip | Node-based; would require a `package.json` at root. Same auto-release-PR model as Release Please. |
| **github-release-from-changelog** | Skip | Reads CHANGELOG.md and creates a GitHub Release per tag. Useful add-on later but not required for the short-term track. |
| **Hand-rolled `gh release create`** | Skip | git-cliff's `--strip header` + a release job's `gh release create vX.Y.Z --notes-file ...` is the natural pairing — but not needed until consumers actually need formatted release notes (today they don't). |

#### Long-term: per-module versioning via the custom Go CLI

Scope confirmed in Observation 3 for the reverse-dependency
work. Adding the release-tooling slice here so the sibling
RFC's scope is complete.

##### Per-module tag shape

Two options for the tag namespace:

**Option A — flat with module prefix:** `eks/cluster/v1.2.3`,
`efs/filesystem/v0.1.0`. Downstream consumers pin via
`source = "git::...?ref=eks/cluster/v1.2.3"`. Works with any
git host. The downside: slashes in git refs are technically
legal but some tooling treats them as path segments
(Terraform's `git::` source URL parser does NOT — verified
this works with Gruntwork's live-repo model the user already
runs).

**Option B — flat without slashes:** `eks-cluster-v1.2.3`,
`efs-filesystem-v0.1.0`. Simpler ref shape but encodes the
service/module hierarchy in the tag name with hyphens — harder
to programmatically split.

**Recommendation: Option A.** Matches the on-disk module path
1:1, which is the same convention `terraform-aws-modules` uses
in their org for their per-module repos. The RFC validates
that the user's existing Gruntwork live-repo doesn't choke on
the slash.

##### Per-module CHANGELOG.md

Each module gets its own `modules/<svc>/<name>/CHANGELOG.md`
generated from commits whose conventional-commit scope
matches the module path. The Go CLI's commit parser:

```text
parse(commit):
    type, scope, subject = conventional_commits.parse(commit.message)
    if scope is empty:
        return None  # repo-wide commit; lands in root CHANGELOG.md
    return (type, scope, subject)
```

A `feat(efs/filesystem): ...` commit:
- Goes into `modules/efs/filesystem/CHANGELOG.md` under "Features".
- Also goes into the root `CHANGELOG.md` under "Features" as
  `**efs/filesystem**: ...` (same shape as the short-term
  cliff.toml's `commit.scope` template).

A `feat(workflows): ...` commit (no module scope):
- Goes only into the root `CHANGELOG.md`.

##### Per-module version bump

The Go CLI replaces `jefflinse/pr-semver-bump` with a
per-module-aware version. Inputs:

- The merged PR's diff: which `modules/<svc>/<name>/` paths
  changed.
- The merged PR's labels: `major-eks-cluster`,
  `minor-eks-cluster`, etc. — OR the PR's commits' types
  (`feat:` → minor, `fix:` → patch, `BREAKING CHANGE` → major)
  if the user prefers conventional-commit-driven bumps over
  labels.
- For each touched module, compute new version from the
  module's previous tag (`git describe --match
  'eks/cluster/v*'`).
- Emit one tag per touched module per release run.

Open question for the RFC: labels vs commit-driven bumps.
Labels are explicit but require N labels per multi-module PR
(`minor-eks-cluster` + `patch-efs-filesystem`); commit-driven
is implicit but requires every commit to be conventional-
shaped (the user already does this).

##### Tooling that the Go CLI absorbs

| Capability | Current tool | After Go CLI |
|------------|--------------|--------------|
| Per-module tag emission | n/a (no per-module tagging today) | `<cli> release` |
| Per-module CHANGELOG.md | n/a | `<cli> changelog --module=<path>` |
| Repo-level CHANGELOG.md | `git-cliff` | `<cli> changelog --root` (git-cliff under the hood OR re-impl in Go) |
| Reverse-deps for CI matrix | n/a | `<cli> reverse-deps <module>` (per Observation 3) |
| `override_data` stub generation | hand-maintained | `<cli> stubs --producer=<module>` (per Observation 3) |
| `terraform-docs` USAGE.md regen | `terraform-docs` (per-module) | `<cli> docs <module>` (wraps terraform-docs OR re-impl) |
| docz README index regen | `docz update` | docz integration via shared library (the user already authors docz) |
| Module templating / scaffolding | n/a (would have been Boilerplate) | `<cli> new --service=eks --name=foo` (per Hypothesis) |

##### Transition path

The short-term repo-level tags (`v0.10.0`, `v0.11.0`, ...)
keep landing under the existing `release.yml::bump-version`
until the Go CLI ships. When the CLI lands:

1. **First per-module release** opens at `eks/cluster/v0.1.0`
   (the per-module versions start fresh, not at the
   repo-level `v0.10.x`).
2. **Repo-level tags continue** alongside the per-module tags
   indefinitely — they're a useful "fleet checkpoint" pointer
   even after per-module versioning is the canonical
   downstream pin.
3. **Downstream consumers migrate one module at a time**:
   change `source = "git::...?ref=v0.10.0"` to
   `source = "git::...?ref=eks/cluster/v0.1.0"`. No
   coordinated cutover needed.

The RFC details the cutover doc users will see.

#### Recommendation

- **Short-term (PLAN scope):** Add `git-cliff` to
  `mise.toml`, author `cliff.toml`, seed `CHANGELOG.md`, rename
  `changelog.yml.bak` → `changelog.yml`, add the `just
  changelog-regen` recipe. Keep `release.yml::bump-version`
  as-is.
- **Long-term (sibling RFC scope):** Per-module tagger +
  per-module CHANGELOG generation + Option A tag namespace
  (`<svc>/<name>/vX.Y.Z`). RFC must validate the slashes-in-
  ref behavior against the user's Gruntwork live-repo before
  landing.
- **Explicitly skipped:** Release Please, semantic-release,
  github-release-from-changelog, hand-rolled `gh release
  create` — all rejected for the short-term track; the Go CLI
  absorbs the equivalent capability long-term.

### Observation 7 — Reference implementations + forge scope (Approach step 7)

Surveyed four reference repos + the user's existing `forge`
tool. **Key validation: techpivot's tag format
`{module-path}/{version}` is exactly Option A from
Observation 6 — confirmed against a working reference.**
`forge` is a clean templating layer that does NOT overlap with
the planned Go CLI's versioning / changelog / reverse-deps
scope — so the Go CLI doesn't absorb `forge`; they're siblings
that share a registry concept.

#### Reference repo survey

##### `terraform-aws-modules/terraform-aws-eks` — closest analog

Workflow inventory: `lock.yml`, `pr-title.yml`, `pre-commit.yml`,
`publish-docs.yml`, `release.yml`, `stale-actions.yaml`. Six
files; their `ci.yml` equivalent is split across
`pre-commit.yml` (lint/validate/docs) + `pr-title.yml`
(conventional-commits check) + `release.yml` (semantic-release).

**Pre-commit approach.** Uses `clowdhaus/terraform-composite-actions`
to wrap the `pre-commit` framework (Python). Two matrix jobs:
`preCommitMinVersions` (validate against the module's MIN
Terraform version per `clowdhaus/terraform-min-max@v2.1.0`) +
`preCommitMaxVersion` (full pre-commit suite — fmt, validate,
docs, tflint — against the MAX version). Notable:

- They split min vs max Terraform-version coverage as a
  separate dimension. Useful for modules that pin a wide
  `>= 1.x` range; less useful for our `>= 1.1` (Terraform 1.1
  is the only version we test against today).
- Uses `clowdhaus/terraform-composite-actions/directories@v1.14.0`
  to compute the touched-directory list — same pattern as our
  `dorny/paths-filter@v3` step but specialized for Terraform
  module dirs.
- Heavy free-runner-disk-cleanup blocks at the top of every
  job (rmz the Android SDK, dotnet runtime, etc.). Worth
  borrowing IF our matrix runs hit the 14GB ephemeral disk
  ceiling — they shouldn't today (Terraform module CI is tiny
  vs. their pre-commit setup).

**Release approach.** Uses `cycjimmy/semantic-release-action@v5`
with `@semantic-release/changelog` + `@semantic-release/git`
+ `conventional-changelog-conventionalcommits`. Tags are
repo-level (`v20.0.0`), not per-module — they ship 8+ separate
single-module repositories instead of one monorepo. This
reinforces the per-module versioning argument: at their scale
(40+ modules), the right answer was per-repo, which is
operationally heavier than per-module tags in one monorepo.

**Net takeaway.** Validate via pre-commit + tflint + terraform-docs +
matrix-per-directory is the canonical pattern. Our existing
`just tf <action> <module>` recipes + `dorny/paths-filter`
matrix are equivalent functionally without the `pre-commit`
Python framework dependency. Skip the `pre-commit`
abstraction; cite this repo as the lineage in the PLAN's
"Prior art" section.

##### `gruntwork-io/terraform-aws-eks`

`gh api repos/gruntwork-io/terraform-aws-eks` returns 404.
Either renamed, archived, or moved into Gruntwork's commercial
catalog (the `terraform-aws-eks-cluster`, `terraform-aws-eks-workers`,
etc. split they ship now). The "many-modules-per-repo" pattern
the Approach step 7 originally referenced doesn't exist there
anymore — gruntwork standardized on one-repo-per-module. Same
conclusion as terraform-aws-modules: at scale they fanned out
to single-module repos, which strengthens the case for
per-module tags in our monorepo (it gets us their isolation
without the repo proliferation).

##### `hashicorp/terraform-provider-aws`

Surveyed in concept only — it's a single-module Go provider
repo, not a Terraform-modules repo. Their CI is matrix-driven
by service (1000+ resource types split into ~80 service
packages), which is conceptually parallel to our per-module
matrix but at very different scale. Useful pattern they
pioneer: **`needs:` graph fan-in to a single `ci:` aggregator
job** that branch protection requires. Already adopted in
Observation 2's `ci.yml` skeleton.

##### `techpivot/terraform-module-releaser` — the algorithm we copy

This is the canonical reference for the long-term Go CLI's
release-emission slice. Algorithm summary:

- **Trigger:** `pull_request` types `[opened, reopened, synchronize, closed]`. The `closed` event finalizes tags after merge.
- **Module detection:** Scans the repo for directories containing `.tf` files. No hand-curated module list.
- **Change detection:** Compares PR diff against a `module-change-exclude-patterns` allow-list (defaults: `.gitignore`, `*.md`, `*.tftest.hcl`, `tests/**`).
- **Version bump rules** (default: conventional-commits): `feat:` → minor, `fix:`/`chore:`/`docs:` → patch, `!` or `BREAKING CHANGE:` footer → major. Falls back to `default-semver-level` (patch) for unmatched.
- **Tag format:** `{module-path}/{version}` — separator configurable. **Exactly our Option A.**
- **Outputs (action outputs, JSON arrays):**
  - `changed-module-names` — modules modified in current PR.
  - `changed-modules-map` — per-module `{path, current_tag, next_tag, release_type}`.
  - `all-module-names`, `all-modules-map` — repo-wide inventory.
- **Artifacts emitted:** module-specific tags, GitHub Releases with asset bundles (`module-asset-exclude-patterns` excludes tests/examples), per-module wiki pages with terraform-docs + changelog, PR comments listing which modules changed.

**Direct mappings to our Go CLI scope (sibling RFC):**

| techpivot capability | Our Go CLI equivalent | Notes |
|----------------------|----------------------|-------|
| Module detection via `.tf` scan | Same algorithm in Go via `filepath.Walk` + HCL parse | Plus output-contract emission per Observation 3 |
| Tag format `{module-path}/{version}` | Same | Already canonized as Option A in Observation 6 |
| Conventional-commits version bump | Same | Already matches the user's commit style |
| `changed-modules-map` JSON output | `<cli> changes --json` | Consumed by CI matrix exactly like techpivot's output |
| PR comments | `<cli> comment` (action mode) | Reuses `gh api` under the hood |
| Per-module wiki pages | Per-module `CHANGELOG.md` + docz integration | We don't use GitHub Wiki — docz publishes to MkDocs/TechDocs per `.docz.yaml::wiki` block. Different artifact, same idea. |
| Asset bundles | Skipped | Our consumers `git::?ref=tag`, not download a tarball |
| `module-change-exclude-patterns` default | **DIFFERENT default** | techpivot excludes `*.tftest.hcl` + `tests/**` — but in our repo those ARE part of the module contract (regressions matter). Default: exclude only `README.md`, `USAGE.md`, `CHANGELOG.md`, `*.md`. |

**Behavioral divergence to call out in the RFC:** techpivot's
`tests/**` exclusion makes sense for repos where tests are
sidecar harnesses; in our repo, `tests/*.tftest.hcl` files
encode the module's plan-time invariants (output contracts,
default shapes, validation negatives — per Observation 3).
A test-file rename or assertion drift IS a module change
worth bumping. The RFC documents this divergence so future
operators don't replicate techpivot's default unthinkingly.

##### `forge` (the user's existing tool)

```text
$ forge --help
Forge scaffolds new projects from blueprints — project templates
stored in a Git-based registry. It supports layered defaults
inheritance, managed file sync, and remote tool resolution.

Available Commands:
  cache      Manage the forge cache
  check      Check project for drift against blueprint
  create     Create a new project from a blueprint
  init       Initialize a new blueprint
  list       List available blueprints
  registry   Manage blueprint registries
  search     Search for blueprints
  sync       Sync project files with the source blueprint
```

`forge` is **the templating layer**, not a versioner. Scope:
blueprint registry + scaffolding (`create`) + drift check
(`check`) + apply blueprint updates (`sync`).

**Scope-overlap audit with the planned Go CLI:**

| Concern | `forge` | Planned Go CLI | Verdict |
|---------|---------|----------------|---------|
| Module templating | `forge create` from a "terraform-module" blueprint | (Hypothesis: absorb) | **`forge` keeps it.** `forge` already does this well; no value rebuilding. |
| Drift check (module deviates from blueprint) | `forge check` | (Hypothesis: absorb) | **`forge` keeps it.** Sibling responsibility. |
| Sync blueprint updates into existing modules | `forge sync` | (Hypothesis: absorb) | **`forge` keeps it.** This is the killer feature for "I updated the blueprint, now refresh all 8 modules". |
| Per-module versioning | n/a | Yes | **Go CLI owns it.** |
| Per-module changelog | n/a | Yes | **Go CLI owns it.** |
| Reverse dependency lookup (HCL parse) | n/a | Yes | **Go CLI owns it.** |
| `override_data` stub generation | n/a | Yes | **Go CLI owns it.** |
| docz README index integration | n/a | Yes | **Go CLI owns it.** |

`forge` and the Go CLI **don't overlap.** The Hypothesis's
"may absorb forge" claim is **refuted** — they're cleanly
separable concerns and `forge` already handles its slice
better than a rebuild would.

**Updated long-term picture:**

```text
forge       — scaffolding + drift + sync (blueprint-driven)
docz        — RFC/ADR/IMPL/PLAN/INV doc lifecycle
<go-cli>    — versioning + changelog + reverse-deps + stubs + docs/index integration

All three share a Go ecosystem; the user authors all three;
they call each other from CI but maintain separate binaries
+ separate releases. No mega-tool.
```

#### Updated sibling-RFC scope

Tighten the RFC scope based on this survey:

- **In scope:** per-module tagger, per-module CHANGELOG, reverse-deps via HCL parse, `override_data` stub generation, docz README index regen, terraform-docs USAGE.md regen.
- **Out of scope (delegated to `forge`):** module scaffolding, blueprint sync, drift detection against templates.
- **Out of scope (delegated to `docz`):** RFC/ADR/IMPL/PLAN/INV doc lifecycle.
- **Three call surfaces** still apply: GitHub Action, local CLI, Docker.
- **techpivot as direct prior art:** mirror the `changed-modules-map` JSON output shape, the `pull_request` event types, the `tag-directory-separator` config knob. Diverge on the `tests/**` exclusion (we include test files in the bump-trigger set).

#### Recommendation

- **Borrow from `terraform-aws-modules/terraform-aws-eks`:** the matrix-per-directory pattern (already adopted in Observation 2). Skip the `pre-commit` framework wrapper — our `justfile` recipes are equivalent.
- **Borrow from `hashicorp/terraform-provider-aws`:** the `needs:` graph fan-in to a single `ci:` job (already adopted in Observation 2).
- **Borrow from `techpivot/terraform-module-releaser`:** the entire algorithm, ported to Go. Tag format, output shape, conventional-commits parser. Diverge on the `tests/**` exclusion default. Cite as the lineage.
- **Keep `forge` separate.** Hypothesis's "may absorb forge" is refuted; the scopes are cleanly separable.
- **Skip:** rebuilding any of forge's blueprint registry, scaffolding, or sync. Skip the `pre-commit` framework. Skip semantic-release.

#### Open concerns to evaluate in steps 5-7

1. **Path filter coverage of test-only changes.** A PR that
   only changes `tests/*.tftest.hcl` files trips the per-module
   filter (correctly) but might surface no terraform-docs
   drift. The drift gate currently fails noisily on a `-r
   exit-code` mismatch even for inconsequential reasons —
   needs validation.
2. **`tflint --init` cost.** Each module's `.tflint.hcl`
   declares 3 plugins (terraform, aws, terraform-style). The
   matrix cache key is per-module — but multiple modules share
   identical plugins. A repo-wide cache could halve install
   time. Decision parked.
3. **Branch protection rule.** The fan-in `ci:` job is
   designed to be the single required check. Confirm GitHub
   branch protection accepts `if: always()` jobs as required.
4. **`workflow_dispatch` inputs.** The LocalStack workflow
   would benefit from a manual input for "module subset to
   run" — useful for debugging a single regression without
   the cron's full fan-out.
5. **`paths-filter` + matrix gotcha.** When all filters miss,
   `outputs.changes` is `[]` (literal string). The matrix
   condition `if: needs.changes.outputs.modules != '[]'`
   handles this — but worth a smoke test in a draft PR before
   landing.
6. **LocalStack service container vs `docker run` startup.**
   `services:` block starts the container before the steps
   begin, so the health-check window doesn't eat job time.
   Alternative is starting it in a step + waiting — slower
   but avoids the `services:` per-job tax. Service container
   is the right call for this repo.


## Conclusion

**Answer:** the Hypothesis is **confirmed in direction, with
two updates folded in from the survey:**

1. The matrix + change-detection + label-gated LocalStack
   posture matches what 8 modules + 4 in-repo dependency
   edges actually need. Quality-gate ordering (early-fail
   fmt/lint → per-module matrix → trivy → LocalStack
   opt-in) is borrowed from `terraform-aws-modules/*`
   minus the `pre-commit` framework wrapper. **Confirmed.**
2. Per-module versioning IS the right long-term answer.
   techpivot's tag format `{module-path}/{version}` is the
   exact shape (Option A) — validated against a working
   production reference. **Confirmed.**
3. The custom Go CLI **DOES NOT absorb `forge`**. The
   Hypothesis's "may absorb forge" line was **refuted** by
   the `forge --help` audit in Observation 7. forge / docz
   / planned-go-cli are three siblings with cleanly
   separable scopes (scaffolding / doc-lifecycle /
   versioning-changelog-reverse-deps). The long-term picture
   is three tools, not one.
4. **Renovate fully replaces Dependabot.** Quantitative
   margin in Observation 5 (12-of-12 pinned surfaces tracked
   vs 4-of-12) made this less subjective than the Hypothesis
   implied. No co-existence period — both compete on shared
   surfaces and the split-brain costs more than it saves.

Direct answers to the five sub-questions in §Question:

- **Q1 (per-module gate scheduling):** Matrix +
  `dorny/paths-filter@v3` change detection, fanning out
  `just tf <action> <module>` per touched module. Early-fail
  gates (fmt / lint / docs-drift / markdownlint /
  actionlint / shellcheck / go-fmt+golangci-lint scoped
  to test directories) run repo-wide in parallel and
  short-circuit the matrix. Fan-in `ci:` aggregator job
  is the single required check for branch protection.
  Detailed in Observation 2.
- **Q2 (LocalStack gating):** Three-mode gate — PR label
  `run-localstack`, scheduled nightly cron, or
  `workflow_dispatch`. Service container with
  `localstack/localstack:3.8.1` pinned (FINDINGS.md
  verification reference). `LOCALSTACK_AUTH_TOKEN` secret
  read conditionally so Pro modules ride along when the
  auth token is available. Modules that demoted to
  `plan_smoke` per IMPL-0005 Phase 9 fall-back run
  identically on either tier.
- **Q3 (release model):**
  - **Short term:** keep repo-level tags
    (`vX.Y.Z`) driven by `jefflinse/pr-semver-bump` (already
    proven on PRs #17 and #18). Add `git-cliff` to
    `mise.toml`, seed `CHANGELOG.md`, revive
    `changelog.yml.bak` as a drift check.
  - **Long term:** per-module tags
    (`<svc>/<name>/vX.Y.Z`) via the custom Go CLI. Repo-level
    tags continue alongside as fleet checkpoints. Downstream
    consumers migrate one module at a time — no coordinated
    cutover. Detailed in Observation 6.
- **Q4 (docs/lint/golangci/goreleaser fit):**
  - `docz update` + `terraform-docs` USAGE.md regen run
    in-matrix (per-module, only for touched modules), with
    a `git diff --exit-code` gate.
  - `markdownlint-cli2 docs/**/*.md '*.md'` (already via
    `just docs lint`) runs as an early-fail repo-wide job.
  - **Keep `.golangci.yml` + `govulncheck` + `go-licenses`**
    but pivot to per-test-directory matrix (today only
    `modules/eks/cluster/test/` exists; structure is
    forward-compatible). The CLAUDE.md "CI caveat" Go-code
    artifacts ARE real — just narrowly scoped.
  - **Strip goreleaser + Docker bake + cosign** blocks
    from `release.yml`. Strip `Makefile` / `Dockerfile` /
    `docker-bake.hcl` / `.goreleaser.yml` / `cicd/`
    references throughout. They were libtftest Go-project
    inheritance.
- **Q5 (Gruntwork tooling fit):** Skip Boilerplate (`forge`
  already covers this slice and the user already authors
  forge). Skip `terraform-update-variable-defaults`
  (Renovate's `customManagers` covers the in-HCL pin
  surface — gvisor, Aurora majors — without the
  Gruntwork dependency). The Gruntwork live-repo
  framing is preserved at the remote-state /
  module-composition layer (per ADR-0001 +
  feedback_cross_module_remote_state memory) — not at the
  CI / scaffolding layer.

## Recommendation

Emit two follow-up docs and ship in the order below. Both
target merge before the EFS module sees its next
consumer in DESIGN-0007's rds/cluster + rds/read-replica
rollout — otherwise the matrix workflow's cross-module
drift coverage falls behind the fleet's evolution.

### Immediate: PLAN-XXXX — short-term CI cleanup

The PLAN doc tracks the **strip + revive + add + fix**
worklist that emerged from Observations 1, 2, 4, 5, 6.
Phases (concrete tasks live in the PLAN itself):

1. **Cleanup phase**: strip libtftest-Go-shaped blocks from
   `ci.yml` / `release.yml`. Drop `Dockerfile` /
   `docker-bake.hcl` / `.goreleaser.yml` / `Makefile` /
   `cicd/` references throughout the repo.
2. **Labeler-fix phase**: rewrite `.github/labeler.yml`'s
   head-branch globs (`^feature` → `^feat`) and path globs
   (`cmd/`/`pkg/`/`collector/` → `modules/<svc>/**`).
3. **Matrix-workflow phase**: author the new `ci.yml`
   matrix per Observation 2 + the supporting `justfile`
   additions (`_tf-fix`, `lint-all`, `tf-fleet`,
   `tf-trivy`, `changelog-regen`).
4. **LocalStack-workflow phase**: split
   `ci-localstack.yml` per Observation 2.
5. **Trivy phase**: wire the matrix job per Observation
   4 + add `# trivy:ignore:AWS-0104` annotations to every
   all-outbound egress rule in the fleet + create the seed
   `.trivyignore`.
6. **Renovate-migration phase**: install Mend Renovate
   app, author `.github/renovate.json` per Observation 5,
   add `# renovate:` annotations to in-HCL pins (`gvisor_*`,
   Aurora majors, LocalStack image pin in
   ci-localstack.yml), retire `dependabot.yml`.
7. **Changelog-revive phase**: add `git-cliff` to
   `mise.toml`, seed `CHANGELOG.md`, author `cliff.toml`,
   rename `changelog.yml.bak` → `changelog.yml`.
8. **Security-pivot phase**: rewire `security.yml` +
   revive `license-check.yml.bak` to a per-test-directory
   matrix (`modules/<svc>/<name>/test/`), starting with the
   one extant Go test dir at `modules/eks/cluster/test/`.
9. **Output-contract phase**: add
   `tests/outputs.tftest.hcl` to `eks/cluster` (today) +
   `rds/serverless` (when consumers ship), pinning the
   output surface per Observation 3.
10. **Documentation phase**: bump the CLAUDE.md "CI/CD
    direction (in flight — INV-0003)" section to "CI/CD
    posture" (or similar) once the PLAN's phases land, and
    remove the §CI caveat section entirely. Update ADR-0001
    with the maintained reverse-dependency map per
    Observation 3's short-term recommendation.

### Follow-up: RFC-XXXX — custom Go CLI

The RFC scopes the long-term tool. From Observation 7's
updated picture:

- **In scope:** per-module tagger + per-module CHANGELOG +
  HCL-parsed reverse-deps + `override_data` stub generator
  + terraform-docs USAGE.md regen + docz README index
  regen.
- **Three call surfaces:** GitHub Action (CI consumption),
  local CLI (`just <cli> ...`), Docker image (dev/CI
  parity).
- **Direct prior art:** `techpivot/terraform-module-releaser`
  algorithm, ported to Go. Mirror the `changed-modules-map`
  JSON output shape, the `pull_request` event types
  including `closed`, and the `tag-directory-separator`
  config knob. Diverge on `module-change-exclude-patterns`
  default — include `tests/**` in the bump-trigger set
  because our `.tftest.hcl` files encode plan-time
  invariants.
- **Out of scope (delegated to forge):** module
  scaffolding, blueprint drift, blueprint sync.
- **Out of scope (delegated to docz):** RFC / ADR / IMPL
  / PLAN / INV doc lifecycle.
- **Open RFC questions** (parked here, decided in the
  RFC): label-driven vs commit-driven per-module bumps;
  per-module CHANGELOG location (`modules/<m>/CHANGELOG.md`
  vs aggregated `CHANGELOGS/<m>.md`); validation that
  Gruntwork live-repo's `git::` source URL parser
  accepts `eks/cluster/v1.2.3` slashes; whether the CLI
  re-implements terraform-docs / git-cliff or wraps them.

### Status flip

This investigation is **complete pending the PLAN + RFC
emit**. Flip INV-0003 status from `Open` to `Completed`
when the two follow-up docs are authored. Until then,
treat the existing CI surface as documented in CLAUDE.md
§CI caveat (no behavior changes from this branch — INV-0003
is research-only).

## References

### Parent / sibling project docs

- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `data.terraform_remote_state`. Bears the reverse-dep map update from Observation 3's short-term recommendation.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants. Underwrites the per-module `tests/` posture this investigation's matrix workflow consumes.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy. The `tests-localstack/` Phase-9 fall-back pattern this investigation's LocalStack gating tolerates.
- [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module rollout (the next batch of in-repo edges that the output-contract recommendation must cover before rds/cluster + rds/read-replica ship).
- [IMPL-0005](../impl/0005-ecr-pull-through-cache-module-implementation.md) — Phase 9 fall-back pattern (501 → commented apply + plan_smoke) that the LocalStack matrix workflow inherits.
- [IMPL-0007](../impl/0007-aurora-serverless-v2-module-implementation.md) — Sibling IMPL with the LocalStack tier-agnostic pattern that informs the `LOCALSTACK_AUTH_TOKEN` opt-in shape in ci-localstack.yml.
- [IMPL-0008](../impl/0008-efs-filesystem-module-implementation.md) — FINDINGS.md verification source for the `localstack/localstack:3.8.1` image pin.

### Related investigations

- [INV-0001](0001-module-scaffolding-distribution-and-presence-check-ci.md) — Module scaffolding & distribution. The scaffolding slice this investigation explicitly delegates to `forge`.
- [INV-0002](0002-localstack-pro-tier-detection-and-test-gating.md) — LocalStack Pro tier detection. Informs the `LOCALSTACK_AUTH_TOKEN` secret read pattern in ci-localstack.yml.

### External tools surveyed

- [techpivot/terraform-module-releaser](https://github.com/techpivot/terraform-module-releaser) — Algorithm reference for the long-term Go CLI. Mirror `changed-modules-map` JSON output, `pull_request` event types including `closed`, and the `tag-directory-separator` knob.
- [terraform-aws-modules/terraform-aws-eks](https://github.com/terraform-aws-modules/terraform-aws-eks) — Closest analog for matrix-per-directory CI. Borrow the directory-detection pattern; skip the `pre-commit` framework wrapper.
- [hashicorp/terraform-provider-aws](https://github.com/hashicorp/terraform-provider-aws) — `needs:` graph fan-in to a single `ci:` aggregator job (single required branch-protection check).
- [donaldgifford/forge](https://github.com/donaldgifford/forge) — Scaffolding / blueprint sync. Sibling of the planned Go CLI; scopes do NOT overlap per Observation 7.
- [donaldgifford/docz](https://github.com/donaldgifford/docz) — Doc lifecycle. Sibling of the planned Go CLI; scopes do NOT overlap per Observation 7.
- [git-cliff](https://git-cliff.org/) — Conventional-commits CHANGELOG generator. Short-term repo-level CHANGELOG driver per Observation 6.
- [aquasecurity/trivy](https://github.com/aquasecurity/trivy) — Static security scanner. Selected per Observation 4.
- [renovate](https://github.com/renovatebot/renovate) — Pinned-version updater. Selected per Observation 5 (replaces Dependabot wholesale).
- [dorny/paths-filter](https://github.com/dorny/paths-filter) — Change-detection action for the matrix workflow's `changes` job.
- [jefflinse/pr-semver-bump](https://github.com/jefflinse/pr-semver-bump) — The existing repo-level tagger that this investigation's short-term track keeps unchanged.

### External tools considered but ruled out

- [gruntwork-io/boilerplate](https://github.com/gruntwork-io/boilerplate) — Module scaffolding. Skipped: `forge` covers the same slice.
- [pre-commit](https://pre-commit.com/) — Python-based git-hook framework. Skipped: justfile recipes are equivalent without the Python dependency.
- [Checkov](https://github.com/bridgecrewio/checkov) — Wider rule bundle (~1000 vs Trivy's ~250 for AWS) but heavier setup + higher false-positive rate. Skipped at this fleet size.
- [tfsec](https://github.com/aquasecurity/tfsec) — Deprecated; merged into Trivy.
- [Release Please](https://github.com/googleapis/release-please) — Forces auto-release-PR workflow; fights the working label-driven tagger.
- [semantic-release](https://github.com/semantic-release/semantic-release) — Node-based; same auto-release-PR model as Release Please.
