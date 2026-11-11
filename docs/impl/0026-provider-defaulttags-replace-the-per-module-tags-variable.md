---
id: IMPL-0026
title: "Provider default_tags replace the per-module tags variable"
status: Draft
author: Donald Gifford
created: 2026-11-11
---

<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL-0026: Provider default_tags replace the per-module tags variable

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-11-11

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Plain-site removal (18 modules)](#phase-1-plain-site-removal-18-modules)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Special-case modules (5 modules)](#phase-2-special-case-modules-5-modules)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Default-tag coverage and the removal gate](#phase-3-default-tag-coverage-and-the-removal-gate)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Upgrade-diff probe](#phase-4-upgrade-diff-probe)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Docs, closure, and release](#phase-5-docs-closure-and-release)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. Where do the plan-tier default-tag assertions live?](#1-where-do-the-plan-tier-default-tag-assertions-live)
  - [2. What form does the permanent removal gate take?](#2-what-form-does-the-permanent-removal-gate-take)
  - [3. What vehicle runs the upgrade-diff probe?](#3-what-vehicle-runs-the-upgrade-diff-probe)
  - [4. Which apply suites run live in this IMPL?](#4-which-apply-suites-run-live-in-this-impl)
  - [5. How is the live-repo rollout tracked?](#5-how-is-the-live-repo-rollout-tracked)
  - [6. Does the bedrock budget get the cost tag explicitly?](#6-does-the-bedrock-budget-get-the-cost-tag-explicitly)
- [References](#references)
<!--toc:end-->

## Objective

Remove the generic `tags` input from all 23 modules that declare it,
so that the fleet's standard tag set arrives only through the AWS
provider's `default_tags` (set in the live repo's generated provider
block). The three sites `default_tags` cannot reach read it back
through `data "aws_default_tags"`. `eks/cluster` names its KMS key
and alias from `var.name`. Coverage proves the default set reaches
resources, and a permanent gate stops a generic `tags` input from
coming back.

**Implements:** DESIGN-0029. All ten OQs were resolved 2026-11-11 as
`a`:

- 1a: remove from all 23 modules.
- 2a: `data.aws_default_tags` at the unreachable sites.
- 3a: `var.name` for the KMS key and alias.
- 4a: keep `cost_tag` and `association_tags`.
- 5a: delete the security-group `Name` guard.
- 6a: accept the one-time tags-only diff, **conditional on Phase 4**.
- 7a: no module-side check that default tags are configured.
- 8a: one PR, one `minor` release.
- 9a: amend ADR-0001 in place.
- 10a: plan coverage, apply read-backs, and a grep gate.

**Branch:** `refactor/drop-module-tags-variables`. This PR carries
DESIGN-0029, this IMPL, and the code, as one commit group per phase.

## Scope

### In Scope

- `variable "tags"` and every `var.tags` reference (code **and**
  comments or descriptions) in the 23 modules listed in DESIGN-0029's
  inventory, including `modules/s3/internal/core`.
- `data "aws_default_tags" "this"` in `eks/managed-node-group`,
  `ecr/org-registry`, `ecr/pull-through-cache`.
- `eks/cluster` KMS key description and alias moved to `var.name`.
- `network/security-group` `Name` guard and its `expect_failures`
  run removed.
- Every plan suite, apply suite, and the `eks/cluster` libtftest Go
  suite updated: `tags` inputs removed, pass-through assertions
  re-sourced to `default_tags`.
- A permanent removal gate: `policy/tags.rego` + unit tests, run by
  the existing static §7 conftest sweep.
- The upgrade-diff probe (Phase 4), which decides whether DESIGN-0029
  OQ 6a holds.
- READMEs, `USAGE.md`, ADR-0001 amendment, CLAUDE.md, release notes.

### Out of Scope

- The live repo's `generate "provider"` change and per-stack bumps
  (DESIGN-0029 Non-Goal). This IMPL only documents them, in the
  release notes (OQ 5b).
- `network/vpc-lookup`'s discovery-filter `*_tags` inputs.
- `test/fixtures/reference-vpc`'s `Network` / `kubernetes.io/role/*`
  tags. These are topology discriminators the fixture must keep, not
  the standard tag set.
- `bedrock/claude-code` `cost_tag` and `eks/pod-identity-access`
  `association_tags`, which are kept (DESIGN-0029 OQ 4a). Only their
  descriptions change, where they mention `var.tags`.
- The Pro-only live runs that the fleet already defers (EKS,
  RDS-Pro). See OQ 4.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met. **Every
phase ends with `just static` and the touched modules' plan suites
green**, so the branch is never left half-threaded.

Fleet-wide mechanics used throughout:

- **Stale test inputs are not self-reporting** (DESIGN-0029 P6). A
  file-level `variables { tags = ... }` is silently ignored, and a
  run-level one only warns. So each phase's "zero leftovers" check is
  a grep, plus a scan of `terraform test` output for
  `does not declare a variable named "tags"`.
- **A reference to an undeclared `var.tags` is a hard error**, both
  in module code and in `expect_failures = [var.tags]`. Those must
  change in the same step as the variable.
- `USAGE.md` is regenerated through `just static` (lock-free
  `~> 6.2` form), never `just tf docs` after a `terraform init`
  (lockfile constraint-drift gotcha).
- Per-module plan run: `just tf test <service>/<module>`. Phase
  tasks name the modules explicitly; `just changed` previews the CI
  matrix for the branch.

---

### Phase 1: Plain-site removal (18 modules)

The 18 modules whose `var.tags` sites are all either `tags =
var.tags` (delete the line) or `merge(var.tags, X)` (becomes
`tags = X`). These follow DESIGN-0029's classification rule
mechanically. No new resources or data sources.

#### Tasks

- [x] 1.1 `bedrock/claude-code`: remove `variable "tags"`. The 5 ×
  `merge(var.tags, local.cost_tag_map)` sites (`alerting.tf:13`,
  `cloudwatch.tf:37`, `iam.tf:17,64`, `inference_profiles.tf:20`)
  become `tags = local.cost_tag_map`. Rewrite the comments in
  `locals.tf:22` and `budget.tf:10` (the budget now inherits
  `default_tags`; the explicit `cost_tag` decision is OQ 6). Rewrite
  the `cost_tag` description that says "NOT merged from var.tags" to
  say it rides on top of provider `default_tags`.
- [x] 1.2 `efs/filesystem`: remove the variable. The 6 plain sites
  (`filesystem.tf`, `kms.tf`, `network.tf` × 4) are deleted.
  `access_points.tf:21` becomes `tags = { Name = each.key }`.
- [x] 1.3 `eks/addons`: remove the **typed object** variable
  (`variables.tf:140-149`) and the 9 plain sites (`main.tf` × 2,
  `ebs_csi.tf` × 2, `efs_csi.tf` × 2, `vpc_cni.tf` × 2,
  `pod_identity_agent.tf`).
- [x] 1.4 `eks/access-entries` (`main.tf`) and
  `eks/pod-identity-access` (`iam.tf`): remove the variable and the
  plain site. Reword `association_tags`'s description
  (`variables.tf:171`): it now merges on top of provider
  `default_tags`, not "separate from var.tags".
- [x] 1.5 `iam/role` (`main.tf`) and `secretsmanager/secret`
  (`main.tf`): remove the variable and the plain site.
- [x] 1.6 RDS × 5: remove the variable and every plain site in
  - `rds/cluster` (9: `cluster.tf`, `instance.tf`, `kms.tf`,
    `network.tf` × 4, `parameter_groups.tf` × 2)
  - `rds/instance` (7)
  - `rds/serverless` (9)
  - `rds/proxy` (6: `iam.tf`, `proxy.tf` × 2,
    `security_group.tf` × 3)
  - `rds/read-replica` (1: `replicas.tf`)
- [x] 1.7 S3 family **in one step**: remove `variable "tags"` and
  `bucket.tf`'s site from `s3/internal/core`, **and** remove the
  `tags = var.tags` argument from the `module "core"` call and the
  root `variable "tags"` in all five purpose modules
  (`access-logs-bucket`, `bucket`, `events-bucket`,
  `evidence-bucket`, `mirror-bucket`). Splitting this step breaks
  plan, because a purpose module passing `tags` to a core that no
  longer declares it is an "unsupported argument" error. The
  `security_baseline` diff-guard pair (`bucket` / `events-bucket`)
  is not touched.
- [x] 1.8 Test-input cleanup for these 18 modules. Delete `tags`
  from every `.tftest.hcl` `variables` block, file-level and
  run-level, in `tests/` and `tests-localstack*/`. This includes
  the `eks/addons` typed-object literals (4 plan files + apply) and
  the RDS Pro apply suites (`rds/cluster`, `rds/instance`).
- [x] 1.9 Re-source the pass-through assertions that would go
  vacuous or red. Add `default_tags` to **that file's** provider
  block, then assert on `tags_all` instead of `tags`:
  - `iam/role/tests/trust.tftest.hcl:180-200`
  - `secretsmanager/secret/tests/default.tftest.hcl:84-97`
  - ~~`bedrock/claude-code/tests/multi_provider.tftest.hcl:50,55`~~
    **No change needed (found in 1.1):** `Team` there is the
    `cost_tag` key, not a `var.tags` key, so those runs stay valid
    and the suite passed 19/19 right after the removal. The
    default-tag proof for bedrock lands in 3.1/3.2.
  - `iam/role/tests-localstack/apply_localstack.tftest.hcl:46,161`
    (provider `default_tags`; the stored-tags read-back now proves
    `default_tags` reached IAM)
- [x] 1.10 Regenerate `USAGE.md` for all 18 modules through
  `just static`. **As built: 17 regenerated** (only `tags` rows
  changed, lock-free `~> 6.2` form held). The 18th,
  `s3/evidence-bucket`, has **no `.terraform-docs.yml`**, so its
  `USAGE.md` is an empty marker block. This is a pre-existing gap
  (since IMPL-0021 / #110) that the static gate cannot see, because
  an empty block regenerates as empty. It is out of scope here and
  recorded as a follow-up.

#### Success Criteria

**Met 2026-11-11.** Zero leftovers. All 18 suites green with run
counts **identical** to a `1fbb4e6` baseline worktree (19, 23, 15,
5, 9, 35, 19, 27, 34, 20, 11, 29, 31, 6, 11, 15, 15, 36). Zero
undeclared-`tags` warnings. `just static` passed.

- `grep -rn 'var\.tags\|variable "tags"'` over the 18 module
  directories returns **zero** lines, comments included.
- `just tf test` green for each of the 18 modules (with `s3/internal/core`
  counted among them), with **zero** `does not declare a variable named "tags"`
  warnings in the output.
- Run counts unchanged from `1fbb4e6` for every suite. Phase 1
  rewrites runs and adds none.
- `just static` green.

---

### Phase 2: Special-case modules (5 modules)

The five modules where removal is not a line deletion: the
`default_tags`-unreachable sites, the KMS naming coupling, the
`Name` guard, and the Go suite.

#### Tasks

- [x] 2.1 `eks/managed-node-group`:
  - Add `data "aws_default_tags" "this" {}`.
  - `launch_template.tf:57,62` become
    `merge(data.aws_default_tags.this.tags, { Name = ... })`, with
    `Name` merged **last** so it keeps winning.
  - Delete the plain sites (`iam.tf` × 2, `main.tf`, and
    `launch_template.tf`'s own `tags`).
  - Remove the variable.
- [x] 2.2 `managed-node-group` byte-identity regression run. With
  the test provider's `default_tags = X` (the same map the old
  `default.tftest.hcl` passed as `tags`), assert both
  `tag_specifications[*].tags` equal
  **the literal map the pre-change module rendered** (`X + Name`).
  This is the plan-tier half of the node-roll guard. Phase 4 proves
  the apply-tier half. **As built:** two asserts in `default_plan` (no
  new run, reusing its `override_data`). The provider `default_tags`
  carries the exact map the suite passed as `tags` before. The
  literals were **proven against `v0.26.0`**: the same asserts, run
  in a `1fbb4e6` worktree with the old `tags` input, pass. Dropping
  the data-source merge reds them (mutation).
- [x] 2.3 `ecr/org-registry`:
  - Add the data source.
  - `templates.tf:76,133` become
    `merge(data.aws_default_tags.this.tags, { artifact_type, managed_by })`.
  - Delete the 5 plain sites (`iam.tf`, `kms.tf`, `publisher.tf`,
    `ssm.tf` × 2).
  - Remove the variable.
- [x] 2.4 `ecr/pull-through-cache`:
  - Add the data source.
  - `template.tf:51` becomes
    `resource_tags = data.aws_default_tags.this.tags`.
  - Delete the plain sites (`credentials.tf`, `iam.tf`).
  - Remove the variable.
- [x] 2.5 `eks/cluster`:
  - Remove the **typed object** (`variables.tf:129-138`).
  - `kms.tf:30` description and `kms.tf:40` alias use `var.name`.
  - Delete the remaining plain sites (`access_entries.tf`,
    `kms.tf`, `main.tf` × 3, `security_group.tf` × 4).
  - Rewrite the `locals.tf:5` comment.
  - Add a plan assertion pinning
    `aws_kms_alias.cluster[0].name == "alias/eks/${var.name}"`.
- [ ] 2.6 `eks/cluster/test` (Go): delete
  `tc.SetVar("tags", …)` (`helpers_test.go:94-100`). An undeclared
  `-var` is a hard error (DESIGN-0029 P7). Then run
  `go build -tags integration ./... && go vet -tags integration ./...`
  in `modules/eks/cluster/test`. No CI gate compiles this suite.
  The exact output-count assertion is unaffected (no output changes).
- [ ] 2.7 `network/security-group`:
  - Remove the variable **with its `Name` validation**
    (`variables.tf:39-50`).
  - The four `merge(var.tags, { Name = … })` sites in `main.tf`
    become `tags = { Name = … }`.
  - Delete `validation.tftest.hcl:458-461` (the
    `expect_failures = [var.tags]` run; a reference to an undeclared
    variable would error).
  - Rewrite `security_group.tftest.hcl:189-207` ("caller tags reach
    the SG / every rule / the all-egress rule") to provider
    `default_tags` + `tags_all`, keeping all three targets.
- [ ] 2.8 Test-input cleanup for these 5, as in 1.8:
  - `eks/cluster`: 4 plan files + apply
  - `eks/managed-node-group`: plan + apply
  - `ecr` × 2: apply
  - `security-group`: apply line 113
- [ ] 2.9 Regenerate `USAGE.md` for the 5 modules through
  `just static`.

#### Success Criteria

- `grep -rn 'var\.tags\|variable "tags"' modules/` returns **zero**
  lines fleet-wide.
- `just tf test` green for the 5 modules with zero undeclared-`tags`
  warnings. The new runs (2.2, 2.3/2.4 site assertions, 2.5 alias)
  each pass, and each is **mutation-checked once**: revert the site
  to omit the data source or `var.name`, confirm the run goes red,
  and restore. This is the standing "a fail-case-only run proves
  nothing" lesson.
- The `security-group` validation suite still passes with one run
  fewer. Its verification header's rule count is updated to match.
- Go suite builds and vets clean under `-tags integration`.
- `just static` green.

---

### Phase 3: Default-tag coverage and the removal gate

Systematic proof that the default set reaches every module (Phases
1–2 only re-sourced the runs that broke), plus the gate that keeps
the variable from returning.

#### Tasks

- [ ] 3.1 Add one `tests/default_tags.tftest.hcl` per module (OQ 1a)
  to the 17 non-s3 modules plus `s3/internal/core`. Each file has
  its own provider block with
  `default_tags { tags = { DefaultTagProbe = "design-0029" } }`
  and asserts `tags_all["DefaultTagProbe"]` on one representative
  resource. The s3 purpose modules are covered by the core suite:
  child-module resources are not assertable from a purpose-module
  suite, and the `security_baseline` output carries no tags.
- [ ] 3.2 Collision runs, in the same files, for every module that
  owns a key. Set that key in `default_tags` too, and assert that the
  **module's** value wins in `tags_all`:
  - `security-group` (`Name`)
  - `efs/filesystem` access points (`Name`)
  - `managed-node-group` `tag_specifications` (`Name`)
  - `bedrock/claude-code` (`cost_tag.key`)
  - `ecr/org-registry` (`artifact_type`)
- [ ] 3.3 Add `default_tags` to every `tests-localstack*/`
  provider block, so each apply exercises the real path.
- [ ] 3.4 Apply-tier read-backs. `iam/role` is already re-sourced in
  1.9. Add to:
  - `network/security-group`: extend `fixtures/verify` to output a
    default-tag key alongside `Name`.
  - `secretsmanager/secret`: read tags through its metadata-only
    fixture. **Never the value-bearing data source.**
- [ ] 3.5 Run the Community apply suites live on token-free
  `localstack/localstack:4.4` (OQ 4a): `iam/role`,
  `network/security-group`, `secretsmanager/secret`, and every other
  Community suite whose provider block changed in 3.3. Record the
  date, image, and result in each `FINDINGS.md`. For the Pro suites
  (eks × 4, rds Pro), add a "default_tags change authored, live
  re-run pending" note, matching IMPL-0020's deferral pattern.
- [ ] 3.6 Removal gate (OQ 2, resolved as an OPA-only variant): add
  `policy/tags.rego`, a `deny` on any `input.variable.tags` (conftest
  hcl2 shape, probed 2026-11-11: `variable "tags"` parses to
  `input.variable.tags` as an array of bodies). The existing static
  §7 sweep runs it over `modules/**/*.tf` with no script change.
  `var.tags` **references** need no rule: once the declaration
  cannot exist, `terraform validate` (static §2) rejects any
  reference to it. Unit tests in `policy/tags_test.rego` (run by
  `conftest verify`, also §7) cover:
  - a `variable "tags"` body: denied
  - a resource `tags = {...}` argument: allowed
  - the kept `association_tags` and `cost_tag` variables: allowed
  - `vpc-lookup`'s `*_subnet_tags` filters: allowed

  Update the `credentials.rego`-centric wording in the §7 comment
  and the final "static gate passed" line to name both policies.
- [ ] 3.7 Mutation-verify the rule in a scratch copy outside the
  repo. Re-add a `variable "tags"` to one module, confirm `just
  conftest` fails naming `tags.rego`, and restore. The `.tftest.hcl`
  side has no permanent gate (OQ 2): it is checked once, here, with
  `grep -rn -B3 'tags *=' modules --include='*.tftest.hcl'`, which
  must show no `tags` inside a `variables` block. It must also show
  no `does not declare a variable named "tags"` warning in any
  Phase 1–3 test run.

#### Success Criteria

- 18 new `default_tags.tftest.hcl` files, all green. Each
  default-key assertion is mutation-checked: remove the provider's
  `default_tags` and the run goes red. Each collision run is
  likewise mutation-checked: swap the merge order and it goes red.
- Community apply suites green on 4.4 with the read-backs passing.
  `FINDINGS.md` records them. Pro suites carry the pending note.
- `conftest verify` passes the new unit tests. The sweep passes on
  the tree and fails on the injected `variable "tags"`.
- The one-off `.tftest.hcl` check is clean.
- `just static` green.

---

### Phase 4: Upgrade-diff probe

Decides DESIGN-0029 OQ 6a. It proves, on a real apply-then-upgrade
cycle, that the migration produces **tags-only in-place updates**,
**no launch-template version**, and **no replacement**.

#### Tasks

- [ ] 4.1 Check out `v0.26.0` into a scratch git worktree outside the
  repo (`git worktree add /tmp/dt-v0.26.0 v0.26.0`). Probe roots
  reference it by **path**, which keeps the probe offline.
- [ ] 4.2 Probe A, plain module. In a scratch root on token-free
  4.4, apply `network/security-group` from the `v0.26.0` worktree
  with `tags = X`.
  1. Add provider `default_tags = X`, keeping `tags = X`, and plan.
     **Expect a clean plan.** This is DESIGN-0029 rollout step 3:
     duplicate identical keys tolerated.
  2. Switch the source to the working tree, drop `tags`, and plan.
     **Expect only `~ tags` in-place updates, `tags_all` unchanged,
     `0 to add, 0 to destroy`.**
  3. Apply, then plan again. Expect **no changes**.
- [ ] 4.3 Probe B, a launch-template replica on token-free 4.4
  (OQ 3a). `managed-node-group`'s live suite needs EKS, which is
  Pro-only, and that suite has **never run live**, so a Pro run
  would have no known-good baseline to compare against: a failure
  could not be told apart from an emulator gap. The node-roll
  mechanism is the launch-template version, because the node group
  pins `version = latest_version`. That makes an EC2-only replica
  sufficient, and EC2 is Community-safe.
  - Build a scratch root holding one `aws_launch_template` whose
    `tags` and both `tag_specifications` blocks (instance, volume)
    are **copied verbatim** from `launch_template.tf` at `v0.26.0`
    (`merge(var.tags, { Name = ... })`). The other arguments are
    minimal stubs.
  - Write a second variant copied verbatim from the working tree
    (`merge(data.aws_default_tags.this.tags, { Name = ... })`, no
    resource `tags`).

  Then:
  1. Apply variant 1 with `tags = X`.
  2. Add provider `default_tags = X` and plan. **Expect a clean
     plan.**
  3. Switch to variant 2 and plan. **Expect `latest_version`
     unchanged**, with only an in-place `tags` update on the
     template itself.
  4. Apply, then plan again. Expect **no changes**.

  The real module's half of this guarantee is the plan-tier
  byte-identity run (task 2.2), which pins the rendered
  `tag_specifications` against the pre-change literal.
- [ ] 4.4 Probe B negative control. From the same applied state,
  plan variant 2 with `default_tags` differing from X in one value.
  **Expect a new launch-template version.** Without this control,
  4.3 cannot distinguish "no roll" from "the probe can't see
  version changes". Destroy the scratch root afterwards.
- [ ] 4.5 Record exact plan excerpts, image, provider and Terraform
  versions in `network/security-group/tests-localstack/FINDINGS.md`
  (probe A) and `eks/managed-node-group/tests-localstack/FINDINGS.md`
  (probe B and the control).
- [ ] 4.6 Write the outcome into DESIGN-0029's OQ resolution note:
  6a **confirmed**, or **reopened** with the observed diff. Remove
  the worktree.

#### Success Criteria

- Probe A step 1 clean, step 2 tags-only in-place, and step 3 clean.
- Probe B shows no new launch-template version. The control shows
  one.
- Results recorded in both FINDINGS files and in DESIGN-0029.
- **If any expectation fails, stop.** Do not start Phase 5. Reopen
  DESIGN-0029 OQ 6 with the evidence before anything ships.

---

### Phase 5: Docs, closure, and release

#### Tasks

- [ ] 5.1 Add a **Tagging** section to each of the 23 module READMEs,
  replacing any `tags` input prose in the 14 that mention it. The
  section says that the module applies no generic tag input, that
  the stack's generated provider block must set `default_tags`, and
  which keys the module sets itself.
- [ ] 5.2 Add a module-specific **Upgrading to v0.27.0** note to:
  - `eks/cluster`: the alias is replaced iff the old
    `tags.ClusterName != name`; the key is untouched.
  - `eks/managed-node-group`: `default_tags` must be byte-identical
    to the old `tags`, with the pre-bump checklist from DESIGN-0029.
  - `network/security-group`: the `Name` guard is gone, and
    resource `Name` wins.
  - `bedrock/claude-code`: the budget gains the provider default
    tags and deliberately **not** the cost tag (OQ 6a). Its
    attribution is the cost-tag *filter*, not a tag on the budget
    object. State this in the module README's Tagging section too,
    not only in the upgrade note, since it is standing behavior.
  - `ecr` × 2: `resource_tags` now track `default_tags`, which
    affects future repositories only.
- [ ] 5.3 Amend ADR-0001 in place (DESIGN-0029 OQ 9a). Add a dated
  note on the "Hoist derivation" paragraph: the tag set is still
  derived in Terragrunt, now delivered through the generated provider
  block's `default_tags`; see DESIGN-0029. The decision is unchanged.
- [ ] 5.4 CLAUDE.md: a fleet **tagging** bullet covering
  - the `default_tags` contract
  - the three `data.aws_default_tags` sites and why they need it
  - the node-roll hazard
  - the `policy/tags.rego` gate, and why `validate` makes a
    reference rule unnecessary
  - probes P5 to P7, as the reusable `terraform test` / libtftest
    lessons

  Also add the `eks/cluster` alias naming change.
- [ ] 5.5 The live-repo rollout is tracked by the release notes only
  (OQ 5b), so the `### RELEASE NOTES` block must carry the full
  per-stack checklist, mirroring DESIGN-0029's sequence diagram:
  - add `default_tags` equal to today's `tags` input
  - plan at the old version (expect clean)
  - bump
  - node-group no-new-version check
  - apply
  - drop the leftover `tags` input

  Put this checklist **first** in the notes, ahead of the removal
  list.
- [ ] 5.6 Statuses: DESIGN-0029 → Implemented, IMPL-0026 →
  Completed. Run `docz update` and revert its unrelated ToC churn,
  restoring any underscore-stripped anchors (known `docz update`
  gotcha). Pass `just docs lint`.
- [ ] 5.7 PR from `refactor/drop-module-tags-variables`:
  - one commit group per phase, plus the design and IMPL docs
  - label `minor`
  - a `### RELEASE NOTES` block carrying DESIGN-0029's
    release-notes list, with the live-repo ordering **first**
  - green `ci-gate` (the full plan matrix runs, since every module
    changed)
- [ ] 5.8 After the merge and tag (`v0.27.0`), refresh the root README
  module table (`just readme`), following the existing post-release
  commit pattern.

#### Success Criteria

- All 23 READMEs have the Tagging section. The 6 upgrade notes are
  present.
- ADR-0001 amended, and CLAUDE.md updated.
- `just docs lint` and `just static` green.
- PR merged with `ci-gate` green, `v0.27.0` tagged, release notes
  published with the per-stack checklist first.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/<23 modules>/variables.tf` | Modify | Remove `variable "tags"` (two typed objects, one with the `Name` guard) |
| `modules/<23 modules>/*.tf` | Modify | ~100 `var.tags` sites deleted or collapsed per DESIGN-0029's rule |
| `modules/eks/managed-node-group/launch_template.tf`, `modules/ecr/org-registry/templates.tf`, `modules/ecr/pull-through-cache/template.tf` (+ a data source in each module) | Modify | `data.aws_default_tags` merges |
| `modules/eks/cluster/kms.tf` | Modify | Description + alias from `var.name` |
| `modules/eks/cluster/test/helpers_test.go` | Modify | Drop `SetVar("tags")` |
| `modules/**/tests*/**.tftest.hcl` | Modify | `tags` inputs removed; pass-through runs re-sourced; provider `default_tags` in apply suites |
| `modules/<18>/tests/default_tags.tftest.hcl` | Create | Default-key + collision coverage |
| `modules/**/tests-localstack*/FINDINGS.md` | Modify | Live results / pending notes; probe A + B |
| `modules/network/security-group/tests-localstack/fixtures/verify/*` | Modify | Default-tag read-back output |
| `modules/*/*/USAGE.md` (+ `s3/internal/core`) | Modify | Regenerated |
| `modules/*/*/README.md` | Modify | Tagging section; upgrade notes |
| `policy/tags.rego`, `policy/tags_test.rego` | Create | Deny `variable "tags"` + unit tests |
| `scripts/static-check.sh` | Modify | §7 comment + pass line name both policies |
| `docs/adr/0001-*.md` | Modify | Dated amendment note |
| `docs/design/0029-*.md` | Modify | OQ 6 outcome; status → Implemented |
| `CLAUDE.md` | Modify | Tagging bullet |

## Testing Plan

DESIGN-0029's Testing Strategy is the authority. Mechanics specific
to this IMPL:

- **Every affected plan suite already uses a real `provider "aws"`
  block** (only `vpc-lookup`, out of scope, uses `mock_provider`).
  `tags_all` is therefore known at plan (DESIGN-0029 P1), and no
  `override_data` workaround is needed.
- **Mutation discipline.** Each new assertion is proven to fail when
  its site is broken (Phase 2, 3 criteria), and the gate is proven on
  injected patterns (3.7). A green run on its own proves nothing.
- **s3 testability boundary.** Child-module resources are not
  assertable from purpose-module suites, so the default-tag proof
  for the s3 family lives in `s3/internal/core`. The purpose modules
  are covered by the static gate (no `tags` argument can be passed)
  and by the core suite.
- **The emulator rule (IMPL-0023).** LocalStack round-trips tags but
  enforces no tag constraints (count, charset, `aws:` prefix). The
  read-backs prove wiring, not AWS-side acceptance.
- **CI.** Every module changed, so `scripts/changed-modules.sh` fans
  the plan matrix out to the whole fleet. Apply tiers stay behind
  `CI_RUN_LOCALSTACK_APPLY` (off), so the live runs in 3.5 and
  Phase 4 are local and recorded in FINDINGS.
- **Gate split.** `policy/tags.rego` covers `.tf` permanently, and
  `terraform validate` covers any `var.tags` reference. The
  `.tftest.hcl` leftovers are checked once in 3.7 rather than gated:
  a stale test input is clutter, not a correctness risk, and OPA
  cannot parse test files.

## Dependencies

- **DESIGN-0029** (Approved 2026-11-11). All OQs resolved.
- **Live repo:** must add provider `default_tags` before any stack
  bumps to `v0.27.0`. This is not a merge blocker for this repo (the
  release can sit unpinned), but it is a **deploy** blocker.
  Communicated by the release-notes checklist (5.5).
- **Token-free `localstack/localstack:4.4`** for 3.5 and both
  Phase 4 probes. Never wire a token into that tier.
- **No LocalStack Pro.** Pro is now available locally, but this IMPL
  deliberately does not depend on it. The eks Pro suites have never
  run live, so there is no baseline to compare a Pro result against.
  The Pro apply-suite re-runs (eks × 4, rds Pro) stay deferred per
  OQ 4a, following the IMPL-0020 task 5.4 precedent.
- No dependency on other in-flight work. The open IMPL-0025 task 3.3
  (sandbox run) is independent.

## Open Questions

> **All resolved 2026-11-11: 1a, 2 (Other: OPA-only variant), 3a,
> 4a, 5b, 6a.** The phases above are written to these resolutions.
> OQ 3 was briefly set to `b` (LocalStack Pro is now available) and
> then returned to `a`: the eks Pro suites have never run live, so a
> Pro run would have no before/after baseline to compare against.
> OQ 6 was left to the author ("either"), and `a` was taken with a
> README note.

### 1. Where do the plan-tier default-tag assertions live?

**Resolved: a.** One `tests/default_tags.tftest.hcl` per module.

- **a. (Recommended) One new `tests/default_tags.tftest.hcl` per
  module (18 files), each with its own provider block carrying
  `default_tags`.** The ~117 existing provider blocks stay untouched,
  so no existing run's `tags_all` changes underneath it. Coverage
  is easy to find, and one probe key is assertable everywhere.
- b. Add `default_tags` to **every** existing plan-suite provider
  block. Every run then exercises the real path, but it is ~117 edits
  of churn, and any existing assertion on exact `tags_all` or `tags`
  equality has to be revisited.
- c. Add the assertions to one existing file per module. No new
  files, but the coverage hides inside unrelated suites, and that
  file's other runs inherit `default_tags`.
- Other: ___

### 2. What form does the permanent removal gate take?

**Resolved: Other (an OPA-only variant of b).** The question asked
was "OPA for what it can cover, shell for the rest". On inspection,
the shell half is unnecessary:

- `policy/tags.rego` denies the `variable "tags"` declaration.
- `terraform validate` (static §2) already rejects any `var.tags`
  reference once no declaration can exist.
- The `.tftest.hcl` half, which OPA cannot parse, is only clutter
  risk, so it is checked once in task 3.7, not gated.

The result is one tool and no shell cruft. Tasks 3.6 and 3.7 carry
it.

- **a. (Recommended) A shell §8 in `scripts/static-check.sh`**
  (grep for `variable "tags"` / `var.tags` in `.tf`, plus awk for
  `tags =` inside `.tftest.hcl` `variables` blocks),
  mutation-verified. It covers both file types, follows the existing
  §5 s3-guard pattern, and stops a scaffold copy from silently
  reintroducing the input.
- b. A conftest rule (`policy/tags.rego`) with unit tests. It fits
  the policy-as-code family, but the hcl2 sweep only parses `.tf`, so
  the `.tftest.hcl` half (the silent-stale-input gap, P6) would still
  need shell.
- c. A one-off IMPL verification grep, with no permanent gate. The
  cheapest option, but nothing stops a new module copied from an old
  scaffold from bringing `variable "tags"` back.
- Other: ___

### 3. What vehicle runs the upgrade-diff probe?

**Resolved: a.** Both probes run on token-free 4.4: the real
`security-group` module for probe A, and the launch-template replica
plus its negative control for probe B (tasks 4.2–4.4). `b` was
considered once Pro became available and was rejected: no eks Pro
suite has a live baseline, so a Pro result could not be compared
one-to-one with pre-change behavior.

- **a. (Recommended) Scratch roots on token-free 4.4: the real
  `network/security-group` module (`v0.26.0` worktree, then the
  working tree) for the plain case, plus a launch-template replica of
  `managed-node-group`'s tag shape with a negative control.** All
  Community-safe and offline. It tests the exact mechanism behind the
  node-roll hazard (launch-template versioning) without EKS.
- b. The full `managed-node-group` module on LocalStack Pro. More
  faithful (the real node group resource), but EKS live runs are
  already deferred fleet-wide, and this would make the release wait
  on a Pro container.
- c. A real AWS sandbox account. The highest fidelity, but there are
  no sandbox credentials in the authoring environment (the same
  blocker as IMPL-0025 task 3.3), and it is costly for a tags check.
- Other: ___

### 4. Which apply suites run live in this IMPL?

**Resolved: a.**

- **a. (Recommended) Run every Community suite whose provider block
  changed, including the three read-back suites (`iam/role`,
  `security-group`, `secretsmanager/secret`), on token-free 4.4. The
  Pro suites (eks × 4, rds Pro) get an "authored, live re-run
  pending" FINDINGS note.** This matches the IMPL-0020 deferral, and
  the plan tier already proves the Pro modules' wiring.
- b. Also run the Pro suites before release. Complete, but it ties
  the release to a Pro container, and the existing eks deferral
  (IMPL-0020 task 5.4) is still open.
- c. Run only the three read-back suites. Faster, but any other
  Community suite whose provider block changed is left unproven
  live.
- Other: ___

### 5. How is the live-repo rollout tracked?

**Resolved: b.** Release notes only. Task 5.5 puts the per-stack
checklist first in the notes.

- **a. (Recommended) A GitHub issue in this repo, linked from the
  PR, with a per-stack checklist mirroring DESIGN-0029's sequence.**
  The release creates the obligation, so the record sits next to the
  release. The live repo can reference it.
- b. Release notes only. That leaves the ordering hazard (silent tag
  loss, node rolls) to whoever reads the notes at bump time.
- c. Hold the release until a live-repo PR adding `default_tags` is
  open. This guarantees readiness, but couples this repo's merge to
  another repo's review queue.
- Other: ___

### 6. Does the bedrock budget get the cost tag explicitly?

**Resolved: a** (author's call). The budget gets the defaults only,
documented in the module README (task 5.2).

`aws_budgets_budget` is deliberately untagged today. Under
`default_tags` it gains the default set automatically.

- **a. (Recommended) Leave it without explicit `tags`; it gets the
  defaults only.** Update the `budget.tf` comment. The budget's
  attribution is its filter (as the comment says), and adding the
  cost tag is a separate behavior change outside this design's
  scope.
- b. Add `tags = local.cost_tag_map` for consistency with every other
  bedrock resource. Harmless, but it is a new behavior change
  smuggled into a removal PR.
- c. Opt the budget out of `default_tags` entirely. There is no
  per-resource opt-out short of the provider's `ignore_tags`, which
  is provider-wide, so this is not practical.
- Other: ___

## References

- DESIGN-0029: the design this implements, including the probes
  P1–P7, the classification rule, and the rollout sequence.
- ADR-0001: amended in Phase 5.
- IMPL-0020: the Pro-deferral pattern (task 5.4), the
  expect_failures and mutation lessons, and the
  `kubelet_node_labels` precedent.
- IMPL-0023: the emulator rule and the mutation-verification
  pattern for static checks.
- IMPL-0025: commit-group-per-phase PR shape and the `minor` release
  precedent.
- `policy/credentials.rego` and `credentials_test.rego`: the
  pattern for `tags.rego`.
