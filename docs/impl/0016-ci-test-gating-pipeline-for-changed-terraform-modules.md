---
id: IMPL-0016
title: "CI test-gating pipeline for changed Terraform modules"
status: In Progress
author: Donald Gifford
created: 2026-07-25
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0016: CI test-gating pipeline for changed Terraform modules

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-07-25

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Design summary (from INV-0006)](#design-summary-from-inv-0006)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Change-detection recipe + matrix emitter](#phase-1-change-detection-recipe--matrix-emitter)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Plan-tier required gate + aggregate check](#phase-2-plan-tier-required-gate--aggregate-check)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Community apply tier](#phase-3-community-apply-tier)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Pro apply tier](#phase-4-pro-apply-tier)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Prune inherited Go-library scaffolding](#phase-5-prune-inherited-go-library-scaffolding)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Documentation + end-to-end verification](#phase-6-documentation--end-to-end-verification)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. Does the plan tier run fleet-wide or changed-modules-only?](#1-does-the-plan-tier-run-fleet-wide-or-changed-modules-only)
  - [2. Where does the change-detection logic live?](#2-where-does-the-change-detection-logic-live)
  - [3. How broad is the cross-cutting fan-out?](#3-how-broad-is-the-cross-cutting-fan-out)
  - [4. How does the Pro tier handle fork PRs (no secret access)?](#4-how-does-the-pro-tier-handle-fork-prs-no-secret-access)
  - [5. What is the required-check enforcement mechanism?](#5-what-is-the-required-check-enforcement-mechanism)
  - [6. Do you also want a standalone DESIGN doc, or is INV-0006 → this IMPL enough?](#6-do-you-also-want-a-standalone-design-doc-or-is-inv-0006--this-impl-enough)
- [References](#references)
<!--toc:end-->

## Objective

Rebuild the repository's GitHub Actions CI around `terraform test` + the existing
`just tf` recipes so that **every PR is gated on the changed modules' tests
passing**, and **a CI run only exercises the module(s) actually changed in that
PR** — replacing the inherited-but-dead Go-library scaffolding that gates nothing
today.

The pipeline has three gate tiers driven by an in-repo change-detection recipe:

1. **Plan tier** (`just tf all` — validate + lint + fmt + plan-only `terraform
   test`) — the universal required gate.
2. **Community apply tier** (`just tf test-localstack`) — real LocalStack
   Community apply, run only for changed modules.
3. **Pro apply tier** (`just tf test-localstack-pro`) — LocalStack **Pro** apply
   for the RDS quartet, unlocked by the `LOCALSTACK_AUTH_TOKEN` repo secret, run
   only for changed modules.

**Implements:** INV-0006 (resolved 1a / 2c / 3a / 4a / 5a / 6a). **Strategy of
record:** ADR-0018 (repo-wide plan baseline + changed-module apply tiers +
all-present-tiers-must-pass gate) — the durable testing-strategy reference this
IMPL builds, layered on ADR-0013 (plan-time `terraform test`) / ADR-0014
(apply-time libtftest) / RFC-0001. Backdrop: INV-0003 (CI/CD option survey),
INV-0002 (LocalStack-Pro auto-detection harness).

## Scope

### In Scope

- An in-repo change-detection mechanism (a `just` recipe delegating to a
  `scripts/*.sh`) that maps `git diff --name-only` → a changed-module list and
  emits a matrix that CI consumes (INV-0006 Q2c).
- Fan-out rules in that same recipe: a change to `test/fixtures/**`, `justfile`,
  `mise.toml`, or `.github/**` re-runs the appropriate dependent modules
  (INV-0006 Q3a).
- A rewritten `ci.yml`: a `detect` job → matrixed `plan`, `test-localstack`, and
  `test-localstack-pro` jobs, with tools from `jdx/mise-action` and LocalStack
  delivered as a `services:` container per apply job (INV-0006 Q4a).
- A single aggregate required status check that branch protection can name even
  though the per-module matrix is dynamic.
- Preservation of the existing PR auto-labeling behavior (the `documentation` /
  `security` / etc. labels currently applied by `ci.yml`'s `labeler` job).
- Deletion of the commented Go-library jobs in `ci.yml`/`release.yml`, the two
  `*.yml.bak` files, and correction of the `labeler.yml` globs; `security.yml`
  (`govulncheck`) kept and scoped to the Go dirs that remain (INV-0006 Q5a).

### Out of Scope

- **The `eks/cluster` Go (libtftest) harness keep-vs-retire decision** (INV-0006
  Q6a) — noted for a follow-up; it interacts with the `x/crypto` alerts tracked
  in INV-0007. This IMPL neither gates nor deletes that harness.
- **Extraction of `tools/bedrock-keyctl`** to its own repo (removes the last
  first-party Go outside the eks/cluster harness) — tracked separately; this
  IMPL only scopes `security.yml` to whatever Go remains.
- The `pr-labels.yml` required-semver-label check and `release.yml`'s
  `bump-version` job — orthogonal and kept as-is.
- Policy-as-code scanning (Checkov/tfsec/trivy) — a possible later addition, not
  part of this gating work.

## Design summary (from INV-0006)

INV-0006's six open questions are already resolved; this IMPL builds the
resolution:

| Q | Resolution | Effect on this IMPL |
|---|------------|---------------------|
| 1 | **1a** | Plan tier is the universal required gate; apply tiers are required **only for changed modules**. |
| 2 | **2c** | Change detection is an **in-repo `just` recipe** shelling `git diff --name-only` — not `dorny/paths-filter`. Version-controlled, unit-testable, locally runnable. |
| 3 | **3a** | That recipe owns fan-out: shared-fixture / tooling / CI changes re-run dependent modules. |
| 4 | **4a** | LocalStack is a `services:` container per apply job (Community image for the Community tier, Pro image + token for the Pro tier). |
| 5 | **5a** | Delete commented Go jobs + `.bak`s; keep `security.yml`/`govulncheck` scoped to remaining Go. |
| 6 | **6a** | `eks/cluster` Go-harness convergence is out of scope; follow-up. |

Grounding facts confirmed during research (2026-07-25):

- **14 leaf modules** at uniform `modules/<service>/<name>/`. All 14 have `tests/`
  and `tests-localstack/`; only the RDS quartet (`cluster`, `instance`, `proxy`,
  `read-replica`) has `tests-localstack-pro/`; only `eks/cluster` has a Go `test/`.
- `ci.yml` today is a single **miswired `labeler` job** (`uses: actions/labeler@v6`
  under a step misnamed "Checkout code", no `with:`) plus fully-commented Go
  boilerplate. That labeler job is what auto-applied `documentation`/`security` to
  recent PRs — labeling must be preserved when the body is rewritten.
- The repo already uses the **`just` recipe → `scripts/*.sh`** pattern
  (`scripts/gen-readme.sh` discovers modules via `find modules -name '*.tf'`;
  `scripts/labels.sh`) — the change-detection script should mirror it.
- Every tool CI needs is pinned in `mise.toml` → `jdx/mise-action` reproduces the
  local toolchain byte-identically.
- `LOCALSTACK_AUTH_TOKEN` is a repo Actions secret, **not exposed to fork PRs**
  (F5) — the Pro tier can gate same-repo branches + push-to-`main` but not
  external forks.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its tasks are
checked off and its success criteria are met.

---

### Phase 1: Change-detection recipe + matrix emitter

The keystone (INV-0006 Q2c + Q3a). A `scripts/changed-modules.sh` invoked by a
thin `just` recipe that turns a git diff into the module lists CI matrixes over.
It must be runnable locally so a developer can preview exactly what CI will test,
and unit-testable without a runner.

#### Tasks

- [x] Add `scripts/changed-modules.sh` that takes a base ref (default
  `origin/main`, overridable via `$1`; plus a `CHANGED_FILES_OVERRIDE` testing
  seam), runs `git diff --name-only <base>...HEAD` (two-dot fallback), and maps
  changed paths under `modules/<service>/<name>/**` to a deduplicated module-slug
  list (`<service>/<name>`), reusing `gen-readme.sh`'s `list_modules` convention.
- [x] Implement the fan-out rules (Q3a): a changed `justfile`, `mise.toml`,
  `.github/**`, or `test/fixtures/terragrunt-inputs.tfvars` path expands to
  **all** modules; a changed `test/fixtures/<name>/**` path expands to that
  fixture's consumers (grepped — `reference-vpc` → its 5 RDS remote-state
  consumers today, auto-widening as EKS/EFS adopt it).
- [x] Emit machine-readable output for CI: a JSON object with `plan`, `community`,
  and `pro` arrays via `jq`. **`plan` is the full module inventory (repo-wide,
  per 1a) — independent of the diff**; `community` = changed modules having
  `tests-localstack/`; `pro` = changed modules having `tests-localstack-pro/`
  (the RDS quartet). Consumable by `strategy.matrix` via `fromJSON`; human summary
  to stderr.
- [x] Add a `just` recipe wrapper (`just changed [base]`, in the `tf` group) that
  runs the script and pretty-prints the tiers (`jq`) so a developer can preview
  what CI will run locally.
- [x] Handle edge cases: empty result (docs-only PR) emits `[]` arrays cleanly;
  a module directory deletion / stray path is dropped by the `intersect`-with-real-modules
  normalization; paths outside `modules/` and the fan-out set are ignored.
- [x] Self-test the mapping: `scripts/changed-modules.test.sh` exercises 9 cases
  (single module, RDS Pro module, `reference-vpc` fan-out, `mise.toml`/`.github`/
  var-file global fan-out, docs-only, stray paths, empty) — **18/18 assertions
  pass**, no network / no LocalStack.
- [x] `shellcheck` clean on both scripts; matches the repo's leading-pipe shell
  style (`gen-readme.sh`), which is the project convention (shfmt's trailing-pipe
  default is not used — `gen-readme.sh` itself doesn't follow it, and there is no
  shfmt gate).

#### Success Criteria

- `scripts/changed-modules.sh <base>` run locally against a synthetic diff prints
  the correct `plan` / `community` / `pro` lists and valid JSON.
- A `test/fixtures/reference-vpc` edit fans out to (at minimum) all its
  remote-state consumers; a `mise.toml` edit fans out to all 14 modules.
- A docs-only diff yields empty apply arrays (and, per Open Question 1, the
  correct plan array).
- The self-test script passes and is runnable with no network / no LocalStack.

#### Result

**Complete.** `scripts/changed-modules.sh` + `scripts/changed-modules.test.sh` +
the `just changed [base]` recipe shipped. All four success criteria met:
`reference-vpc` fans out to its 5 RDS consumers, `mise.toml`/`.github`/var-file
fan out to all 14, docs-only/stray/empty diffs yield `[]` apply tiers with the
plan tier staying repo-wide (14). Self-test **18/18** green, shellcheck clean,
no network. Corrected a stale "15 modules" count in this doc + research notes to
the authoritative **14** (`list_modules`).

---

### Phase 2: Plan-tier required gate + aggregate check

Replace `ci.yml`'s dead body with the universal plan gate, and stand up the
single aggregate status check that branch protection will require (needed because
the per-module matrix is dynamic and cannot be named job-by-job in branch
protection).

#### Tasks

- [x] Rewrite `ci.yml`: a `detect` job (checkout with `fetch-depth: 0` +
  `jdx/mise-action`) runs the Phase-1 recipe and sets `outputs.plan` /
  `outputs.community` / `outputs.pro` via `$GITHUB_OUTPUT` (base ref =
  `pull_request.base.sha` on PRs, `github.event.before` on push).
- [x] Add a `plan` job: `strategy.matrix.module` from `fromJSON(needs.detect.
  outputs.plan)` (the **repo-wide** module list — all modules, no LocalStack, per
  1a), `fail-fast: false`, running `just tf all ${{ matrix.module }}` (validate +
  lint + fmt + plan `terraform test`) with tools from `jdx/mise-action`.
- [x] Add an aggregate `ci-gate` job that `needs: [detect, plan]` (extended in
  Phases 3–4), `if: always()`, that fails if any needed job's result is
  `failure`/`cancelled` and passes when apply matrices are legitimately
  empty/skipped — the **one** job branch protection will require. Gate
  semantics: for a changed module the run is green only when **every tier that
  module ships** is green (**all-present-tiers-must-pass**).
- [x] Preserve PR auto-labeling: moved the (mis-wired) `labeler` step into its own
  correctly-wired `.github/workflows/labeler.yml` (`actions/labeler@v6`, job name
  `Label PR` preserved so the check name is unchanged).
- [x] Add `concurrency` (group by PR number / ref, `cancel-in-progress: true`) so
  superseded runs are cancelled; top-level `permissions: contents: read`
  (labeler workflow adds `pull-requests: write`).
- [ ] **Deferred to Phase 6.** Configure branch protection on `main` to require
  the `ci-gate` check (+ keep `Check Required Labels`). A required status check
  can only be enforced once the check has run at least once, so this is sequenced
  into the Phase-6 validation PR (which proves `ci-gate` green before it is made
  required).

#### Success Criteria

- On a PR that changes one module, the `plan` matrix runs exactly the intended
  module(s) (or all, per Open Question 1) and `just tf all` passes green.
- The `ci-gate` job is a required check on `main` and correctly blocks a PR whose
  plan job fails.
- PRs still receive their path/branch labels (parity with today's behavior).
- A docs-only PR passes `ci-gate` without running any apply job.

#### Result

**Code complete; static validation green.** `ci.yml` rewritten as
`detect` → `plan` (repo-wide matrix) → `ci-gate` (aggregate required check),
with `concurrency` + least-privilege `permissions`; PR auto-labeling moved to
`labeler.yml` preserving the `Label PR` check name. **yamllint + actionlint
clean** (actionlint shellchecks the run blocks). The `detect` emission and
`fromJSON` matrix shape verified locally against synthetic diffs. Branch-protection
enforcement + the live "runs green on a PR" success criteria are exercised in
**Phase 6** (they need the workflow on a PR / an existing check run) — everything
that can be built and statically proven now is done.

---

### Phase 3: Community apply tier

Add the real LocalStack **Community** apply, scoped to changed modules that carry
a `tests-localstack/` suite, backed by a `services:` container.

#### Tasks

- [x] Add a `test-localstack` job: `strategy.matrix.module` from
  `fromJSON(needs.detect.outputs.community)`, guarded by
  `if: needs.detect.outputs.community != '[]'` (empty matrix skips) **and** the
  same-repo condition (see revision below).
- [x] ~~Declare a `localstack/localstack` (Community, token-free) container~~
  **Revised → LocalStack Pro `services:` container** (`localstack/localstack-pro:2026.7.0`
  + `LOCALSTACK_AUTH_TOKEN`), `:4566` + health check. **Why:** the premise that
  `tests-localstack/` is Community-safe is false for most modules — `eks/{cluster,
  addons,managed-node-group,pod-identity-access}`, `efs/filesystem`, and
  `rds/serverless` do real applies against **Pro-only** AWS APIs (EKS/EFS/Aurora
  `501` on the Community image, per their `FINDINGS.md`); only `network/vpc-lookup`
  is genuinely token-free, and the `ecr`/RDS-quartet `tests-localstack/` suites are
  plan-only. Pro is a Community superset, so one Pro-backed tier covers all — far
  simpler than per-module image selection. The recipe wires its own
  `AWS_ENDPOINT_URL`/key/secret/region.
- [x] Run `just tf test-localstack ${{ matrix.module }}` via `jdx/mise-action`.
  The `reference-vpc` (real NAT) applies were confirmed green **locally against
  Pro `2026.7.0`** this cycle (vpc-lookup 3/3, efs 3/3, each eks 2/2, serverless
  3/3); the **CI-runner** confirmation + wall-clock is recorded in Phase 6's live
  validation PR.
- [x] Add `test-localstack` to the `ci-gate` `needs:` list + skip-tolerant loop
  (a skipped/empty apply matrix counts as pass).

#### Success Criteria

- A PR touching a module with a `tests-localstack/` suite runs its apply green
  against the service container.
- A PR touching only no-apply modules does **not** spin up the apply job (empty
  matrix / fork PR → skipped), and `ci-gate` still resolves correctly.
- The `reference-vpc` fan-out (Phase 1) correctly triggers the applies of its
  consumers when the fixture changes.

#### Result

**Code complete; static validation green; local apply-parity proven.** Added the
`test-localstack` matrix job over `detect.outputs.community`, backed by a
Pro-pinned LocalStack `services:` container, fork-guarded. `ci-gate` extended to
`needs: [detect, plan, test-localstack]` with skip-tolerance. yamllint +
actionlint clean. **Design revision recorded:** the "Community token-free image"
premise (INV-0006 F5 / Phase-3 draft) was corrected to a Pro-backed tier — the
evidence is each module's `FINDINGS.md` (EKS/EFS/Aurora are Pro-only) and this
cycle's local sweep, which ran those `test-localstack` suites green **only**
against the Pro container. ADR-0018 §1's taxonomy "Needs" column updated to match.
Live CI confirmation is Phase 6.

---

### Phase 4: Pro apply tier

Add the LocalStack **Pro** apply for the RDS quartet, unlocked by
`LOCALSTACK_AUTH_TOKEN`, and confirm F4 (no macOS named-volume workaround needed
on a Linux runner).

#### Tasks

- [x] Add a `test-localstack-pro` job: `strategy.matrix.module` from
  `fromJSON(needs.detect.outputs.pro)`, guarded by `if:` on a non-empty matrix
  **and** the same-repo condition (fork PRs cannot read the secret — F5 / Q4a).
- [x] Declare a `localstack/localstack-pro:2026.7.0` `services:` container with
  `LOCALSTACK_AUTH_TOKEN: ${{ secrets.LOCALSTACK_AUTH_TOKEN }}`, `:4566` +
  health check. The Pro recipe wires its own
  `AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566` (resolves to
  127.0.0.1 → the mapped service port).
- [x] Run `just tf test-localstack-pro ${{ matrix.module }}`. **F4 resolved by
  design:** a `services:` container declares no `volumes:`, so
  `/var/lib/localstack` is in the container's own layer (no host bind-mount) — the
  macOS Docker-Desktop `initdb`-ownership issue that forces the named-volume
  workaround locally cannot occur on the Linux runner. The **live run + the
  RDS-quartet `FINDINGS.md` note** are executed in Phase 6.
- [x] Add `test-localstack-pro` to the `ci-gate` `needs:` list with skip/empty
  tolerance; fork-PR behavior documented (ADR-0018 §5 — apply tiers skip, plan
  tier still gates).

#### Success Criteria

- A PR touching an RDS-quartet module runs its Pro apply green against the Pro
  service container using the repo secret.
- The Linux named-volume question (F4) is settled with a real run and recorded in
  the affected modules' `FINDINGS.md`.
- Fork PRs degrade gracefully per Open Question 4 (they do not hard-fail on the
  missing secret), while same-repo PRs are fully gated.

#### Result

**Code complete; static validation green; F4 resolved structurally.** Added the
`test-localstack-pro` matrix job over `detect.outputs.pro` (Pro `services:`
container, fork-guarded) and extended `ci-gate` to `needs: [detect, plan,
test-localstack, test-localstack-pro]`. yamllint + actionlint clean. The Pro
applies were verified green locally against Pro `2026.7.0` this cycle
(cluster/instance/proxy 3/3, read-replica 2/2). The named-volume question (F4) is
answered by the services-container model (no host bind-mount → no `initdb`
ownership failure); the **live CI run that proves it on `ubuntu-latest`** and the
FINDINGS.md notes are Phase 6, which owns end-to-end verification.

---

### Phase 5: Prune inherited Go-library scaffolding

Remove the dead Go-library CI cruft (INV-0006 Q5a) now that the Terraform
pipeline is the real gate.

#### Tasks

- [x] `ci.yml`'s commented Go jobs are gone (fully rewritten in Phase 2); removed
  the commented `release`/`changelog-sync`/`docker` jobs from `release.yml`
  (kept the live `bump-version`, trimmed its permissions to `contents: write` +
  `pull-requests: read`).
- [x] Deleted `.github/workflows/changelog.yml.bak` and
  `.github/workflows/license-check.yml.bak`.
- [x] Fixed `.github/labeler.yml`: the dead `cmd/`/`pkg/`/`collector/`/`config/`/
  `exporter/`/`Makefile`/`.goreleaser.yaml`/`.codecov.yml`/`.chglog.yml`/`docker`
  globs are replaced with the real tree (`tools/**/*.go` + `modules/**/*.go`,
  `**/go.mod`, `docs/**`, `.github/**`, the actual root config files + `**/.tflint.hcl`
  + `scripts/**`); branch-prefix labels kept.
- [x] Scoped `security.yml`/`govulncheck` to a matrix over the two real Go modules
  (`tools/bedrock-keyctl`, `modules/eks/cluster/test`) — there is no root `go.mod`.
  `continue-on-error` + SARIF-per-module keeps this non-gating push/cron scan from
  reddening on the out-of-scope CVEs triaged in INV-0007.
- [x] Reconciled `dependabot.yml`: dropped the broken `docker@cicd` entry (no
  `cicd/` dir / no Dockerfile) and repointed `gomod` from the non-existent root to
  `directories: [/tools/bedrock-keyctl, /modules/eks/cluster/test]` (security-only,
  `open-pull-requests-limit: 0`).
- [x] Updated CLAUDE.md's CI-caveat paragraph: it now describes the real
  `ci.yml` test-gating pipeline (detect → plan/community/pro → `ci-gate`), the
  `labeler.yml` split, the trimmed `release.yml`, and the scoped `security.yml`.

#### Success Criteria

- `ci.yml` and `release.yml` contain only live, correct jobs — no commented
  Go-library blocks; no `.bak` workflow files remain.
- The labeler applies accurate labels for a Terraform-module change (e.g. a
  `modules/rds/**` edit no longer relies on dead Go globs).
- `security.yml` runs green (or is correctly a no-op) against the remaining Go,
  with no scan errors on missing paths.
- CLAUDE.md no longer claims "there is no CI that gates module correctness."

#### Result

**Complete.** Inherited Go-library CI cruft removed: two `.bak` workflows deleted,
`release.yml` trimmed to `bump-version`, `labeler.yml` retargeted to the real
tree, `security.yml`/`govulncheck` scoped to the two actual Go modules
(`continue-on-error`, non-gating), `dependabot.yml`'s dead `docker@cicd` +
root-`gomod` entries fixed, and CLAUDE.md's CI-caveat rewritten. yamllint +
actionlint clean across all workflows; markdownlint clean. The `eks/cluster` Go
harness + `bedrock-keyctl` extraction stay out of scope (Q6a / INV-0007).

---

### Phase 6: Documentation + end-to-end verification

Prove the pipeline on a real PR and record the design.

#### Tasks

- [ ] Open a throwaway/validation PR that touches (a) one plan-only module, (b)
  one Community-apply module, (c) one RDS-Pro module, and (d) the
  `reference-vpc` fixture — confirm each triggers exactly the expected matrix
  entries and that `ci-gate` blocks/passes correctly.
- [ ] Confirm a docs-only PR runs no apply jobs and `ci-gate` passes.
- [ ] Record the CI wall-clock per tier (plan, Community apply w/ NAT, Pro apply)
  and note it in the IMPL Results.
- [ ] Ensure the README **testing coverage matrix** (`scripts/gen-readme.sh` →
  the `Plan tests | LocalStack | Pro` module table + the "Testing tiers" table)
  represents exactly what the gate enforces per module (ADR-0018's
  coverage-visibility decision); wire `just readme --check` into CI as a drift
  guard so a stale matrix fails the build.
- [ ] Document the change-detection recipe + fan-out rules and the new CI tiers in
  CLAUDE.md ("Common commands" / a new "CI" section) and the affected modules'
  `FINDINGS.md` (Linux named-volume outcome from Phase 4).
- [ ] Regenerate doc indexes (`docz update`) and flip IMPL-0016 → Completed;
  update INV-0006 status to Concluded if not already.

#### Success Criteria

- The validation PR demonstrates correct per-tier, per-module gating end-to-end
  on real runners.
- Every required check is green and `ci-gate` is enforced on `main`.
- CLAUDE.md + FINDINGS.md reflect the pipeline and the Linux named-volume finding.
- IMPL-0016 is marked Completed with a per-phase Result summary.

#### Result

**In Progress — apply tiers blocked on external LocalStack licensing.** The
pipeline **code** is complete and proven on real runners; the live apply-tier
verification is blocked on a LocalStack Pro license that will not activate
headless, which is outside this repo.

Verified green on CI (run `30262147311`, branch `feat/ci-test-gating-changed-modules`):

- **Plan tier — 14/14 green**, plus `detect`, `readme-check`, and the `labeler`
  workflow. `detect` fans the full inventory to `plan` and the changed set to the
  apply matrices exactly as designed.
- **`tflint` rate-limit hardening.** The first full run flaked one plan job
  (`bedrock/claude-code`) on `tflint --init` hitting GitHub's unauthenticated
  60/hr API limit (`403`) — 14 concurrent plan jobs each fetch the AWS ruleset.
  Fixed by passing the runner's built-in `GITHUB_TOKEN` to the plan step
  (5000/hr); the job is green on the next run.
- **Community apply concurrency guard.** `max-parallel: 4` caps concurrent
  LocalStack Pro license activations in the community matrix.

Apply-tier blocker (all 18 apply jobs, both community and Pro):

- Every apply job's LocalStack Pro service container exits at init with
  `code 55 — License activation failed! … The credentials defined in your
  environment are invalid`, before any `terraform test` runs. Because all apply
  jobs share the one `localstack/localstack-pro:2026.7.0` service container, even
  the token-free `network/vpc-lookup` suite fails (container never goes healthy).
- **Root cause is external, not a pipeline defect.** The `LOCALSTACK_AUTH_TOKEN`
  secret was rotated (and freshly regenerated), yet a plain local
  `docker run -e LOCALSTACK_AUTH_TOKEN localstack/localstack-pro:2026.7.0` fails
  identically — so the token/account does not grant **headless** Pro activation.
  The maintainer's normal local container works because it was activated by a
  different path (e.g. a cached license via `localstack auth login`), which keeps
  a running container valid even after a token/subscription lapses. This is a
  LocalStack subscription/activation matter to resolve in the LocalStack web app.
- The CI apply path itself was de-risked and is sound: the `reference-vpc`
  fixture self-provisions the remote-state S3 bucket (`aws_s3_bucket.state`,
  `force_destroy = true`) in the `run "setup"` step, the recipe wires
  endpoint/creds/region, and the assume-role-against-LocalStack-STS read is
  proven (IMPL-0015) — so the CI environment mirrors the local apply runs that
  already pass. The only local-vs-CI difference (named volume vs. `services:`
  container) is the F4 non-issue already documented in Phase 4.

Resolution paths (maintainer decision):

1. **Fix the license** (keeps the gate as designed — apply tiers required when a
   module ships them): restore headless Pro activation, then re-run and confirm
   the apply tiers green.
2. **Graceful-skip to ship now** (trades away the "all present tiers must pass"
   rule when no valid token is available): a `detect`-job `has_token` output gates
   the apply tiers, `network/vpc-lookup` moves to the token-free Community image,
   and the invalid secret is removed so the tiers skip cleanly rather than
   hard-fail. `ci-gate` already tolerates skipped tiers.

Remaining Phase 6 tasks (validation PR matrix proof, wall-clock capture,
FINDINGS.md notes, `docz update`, status flip, branch protection on `ci-gate`)
stay open until path 1 or 2 lands.

---

## File Changes

| Path | Action | Description |
|------|--------|-------------|
| `scripts/changed-modules.sh` | Create | git-diff → module-list + fan-out + JSON matrix emitter |
| `scripts/changed-modules.test.sh` | Create | self-test of the mapping/fan-out |
| `justfile` | Modify | add `just tf changed` / `ci-matrix` recipe wrapping the script |
| `.github/workflows/ci.yml` | Modify | rewrite → `detect` / `plan` / `test-localstack` / `test-localstack-pro` / `ci-gate`; drop commented Go jobs |
| `.github/workflows/labeler.yml` (or a labeling job) | Create | preserve correctly-wired PR auto-labeling |
| `.github/labeler.yml` | Modify | retarget globs to the real tree |
| `.github/workflows/release.yml` | Modify | remove commented Go-release jobs (keep `bump-version`) |
| `.github/workflows/security.yml` | Modify | scope `govulncheck` to remaining Go dirs |
| `.github/workflows/changelog.yml.bak`, `license-check.yml.bak` | Delete | inherited cruft |
| `.github/dependabot.yml` | Modify | reconcile docker/gomod entries with reality |
| `CLAUDE.md` | Modify | replace the "CI caveat"; document the new pipeline |
| `docs/impl/0016-*.md` | Modify | check off tasks + Results per phase |

## Testing Plan

- **Local:** `scripts/changed-modules.test.sh` (mapping/fan-out unit cases, no
  network); `just tf changed <base>` previews against real branches; `just tf all
  <m>` parity with what CI runs.
- **CI dry-run:** a validation PR (Phase 6) exercising each tier and the fan-out,
  plus a docs-only PR proving empty-matrix skip.
- **Pro tier:** one real `ubuntu-latest` Pro apply to settle the F4 named-volume
  question.
- **Regression guard:** `ci-gate` required on `main` ensures the gate cannot be
  bypassed by a green-but-empty run.

## Dependencies

- `LOCALSTACK_AUTH_TOKEN` repo Actions secret (present) — Phase 4 only.
- `jdx/mise-action` + `mise.toml` pins (present) — all tiers.
- `actions/labeler@v6` + `.github/labeler.yml` — labeling parity.
- Branch-protection admin access to set `ci-gate` as required — Phase 2.
- INV-0007 outcome (bedrock-keyctl extraction, `x/crypto` alerts) informs the
  final `security.yml` scope — Phase 5, non-blocking.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
>
> **Resolved 2026-07-25 — 1a, 2a, 3a, 4a, 5a, 6a.** The plan tier runs
> **repo-wide on every PR** (all modules, no LocalStack — 1a); change detection
> is a `scripts/changed-modules.sh` + thin `just` wrapper (2a) that owns the
> tiered fan-out (toolchain/CI → all modules; shared fixtures → their consumers —
> 3a); the Pro tier is gated on same-repo PRs and degrades to a soft status on
> forks (4a); the required merge gate is a single aggregate `ci-gate` job (5a);
> and this IMPL stands alone with **no separate DESIGN** — the durable
> testing-strategy reference is **ADR-0018** instead (6a). The gate semantics are
> **all-present-tiers-must-pass**: a changed module that ships plan +
> `tests-localstack/` + `tests-localstack-pro/` must be green on all three; the
> README carries the auto-generated coverage matrix that makes that legible.

### 1. Does the plan tier run fleet-wide or changed-modules-only?

INV-0006 Q1a makes the plan tier "required on every PR" but leaves whether it
runs for *all* modules or only *changed* modules unstated. Plan tests are ~1s
each (≈15–25s fleet-wide).

- **a — Fleet-wide: `just tf all` for all 14 modules on every PR.** *(recommended)*
  Simplest possible universal gate, catches cross-module breakage a diff-scoped
  run would miss, and the cost is trivial. The matrix scoping is reserved for the
  expensive apply tiers only.
- **b — Changed-modules-only, same as the apply tiers.** One consistent scoping
  mechanism for all three tiers; matches the investigation's literal "only
  exercise changed modules" goal; slightly faster but risks missing a
  shared-code regression the fan-out rules don't model.
- **other.**

### 2. Where does the change-detection logic live?

Q2c mandates an in-repo recipe (not `dorny/paths-filter`), but not its form. The
repo already pairs thin `just` recipes with `scripts/*.sh` (`gen-readme.sh`,
`labels.sh`).

- **a — `scripts/changed-modules.sh` + a thin `just tf changed` wrapper.**
  *(recommended)* Matches the existing script pattern, `shellcheck`-able,
  self-testable in bash, keeps the justfile readable, zero new toolchain.
- **b — A pure inline `just` recipe** (logic lives in the justfile). Fewer files,
  but recipe bodies are awkward to unit-test and harder to read for non-trivial
  set logic.
- **c — A small Go program under `tools/`.** Strongly typed + table-tested, but
  reintroduces first-party Go right as `bedrock-keyctl` is leaving, and adds a
  build step to the `detect` job.
- **other.**

### 3. How broad is the cross-cutting fan-out?

Q3a says shared-fixture / tooling / CI changes fan out to "all (or all
dependent) modules." The breadth trades safety against apply-minutes (each
`reference-vpc` apply pays a ~1–2 min real-NAT cost).

- **a — Tiered fan-out.** *(recommended)* `justfile` / `mise.toml` / `.github/**`
  → **all** modules (toolchain/CI-wide blast radius); `test/fixtures/reference-vpc`
  and other shared fixtures → **only that fixture's consumers**, computed by
  grepping which modules reference it. Safe where it must be, cheap elsewhere.
- **b — Any cross-cutting change → all 14 modules.** Trivially correct and
  simplest to reason about, but re-runs every apply suite (including the slow Pro
  quartet) for an unrelated fixture tweak.
- **c — Directly-changed modules only; a nightly scheduled full run covers
  shared-fixture drift.** Fastest PRs, but a `reference-vpc` regression can merge
  and only surface hours later on the nightly.
- **other.**

### 4. How does the Pro tier handle fork PRs (no secret access)?

`LOCALSTACK_AUTH_TOKEN` is unavailable to `pull_request` runs from forks (F5), so
the Pro tier physically cannot run there.

- **a — Same-repo branches + push-to-`main` are fully Pro-gated; fork PRs skip the
  Pro tier with a neutral/soft status and a comment, and a maintainer re-runs
  after review.** *(recommended)* This is an internal-first repo, so fork PRs are
  rare; this degrades gracefully without a hard failure and never blocks on a
  missing secret.
- **b — Require the Pro tier on all PRs.** Maximal enforcement, but every fork PR
  hard-fails on the missing secret — untenable if external contributions ever
  happen.
- **c — Move the Pro apply entirely to a post-merge gate on `main` (never on
  PRs).** Simplest secret story, but Pro regressions land before they're caught.
- **other.**

### 5. What is the required-check enforcement mechanism?

A dynamic `strategy.matrix` produces per-module job names that branch protection
cannot enumerate ahead of time, so "require the tests" needs an indirection.

- **a — A single aggregate `ci-gate` job** that `needs:` all tier jobs and fails
  unless every one succeeded-or-legitimately-skipped; branch protection requires
  only `ci-gate`. *(recommended)* Stable check name, matrix-agnostic, standard
  GitHub pattern.
- **b — Mark each matrix job required in branch protection.** Impossible to
  enumerate reliably with a dynamic matrix; brittle as modules are added/removed.
- **c — Use a marketplace "wait for all checks" app / merge queue.** More
  machinery and another dependency to trust for the same outcome as (a).
- **other.**

### 6. Do you also want a standalone DESIGN doc, or is INV-0006 → this IMPL enough?

INV-0006's Recommendation says "Promote to a DESIGN + IMPL," but you asked only
for an IMPL.

- **a — IMPL only (this doc); no separate DESIGN.** *(recommended)* INV-0006's
  Findings + resolved open questions already carry the design rationale; a
  separate DESIGN would duplicate it. This IMPL links back to INV-0006 as the
  decision record.
- **b — Author a DESIGN-0018 first** and reduce this IMPL to pure phase-tracking
  that references it. More ceremony; useful only if the CI design needs wider
  review before build.
- **other.**

## References

- ADR-0018 — the fleet testing strategy this IMPL builds (repo-wide plan +
  changed-module apply tiers + all-present-tiers-must-pass gate + coverage
  matrix).
- ADR-0013 / ADR-0014 / RFC-0001 — the framework-level testing decisions
  (`terraform test` plan-time / libtftest apply-time) ADR-0018 layers on.
- INV-0006 — CI test gating on changed terraform modules with LocalStack (the
  decision record this implements; resolved 1a/2c/3a/4a/5a/6a).
- INV-0003 — CI/CD options for a Terraform-modules monorepo (option survey).
- INV-0002 — fleet-wide LocalStack-Pro auto-detection harness for tests.
- INV-0007 — open Renovate/Dependabot PRs + security triage (`x/crypto` alerts in
  the eks/cluster Go harness; bedrock-keyctl extraction).
- `.github/workflows/ci.yml` — the mostly-dead current pipeline being rebuilt.
- `justfile` — the `just tf {validate,lint,fmt,test,test-localstack,test-localstack-pro,all}`
  recipes CI wraps.
- `scripts/gen-readme.sh` — the existing module-discovery pattern the
  change-detection script mirrors.
- `project-localstack-rds-needs-named-volume` (memory) — the macOS-only gotcha
  Phase 4 confirms is absent on Linux.
