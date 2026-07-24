---
id: IMPL-0015
title: "Terragrunt multi-account remote-state migration"
status: Draft
author: Donald Gifford
created: 2026-07-24
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0015: Terragrunt multi-account remote-state migration

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-07-24

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [The uniform transformation](#the-uniform-transformation)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Spike the account-scoped read on LocalStack](#phase-1-spike-the-account-scoped-read-on-localstack)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Shared foundation](#phase-2-shared-foundation)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: RDS consumer migration](#phase-3-rds-consumer-migration)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: EKS consumer migration](#phase-4-eks-consumer-migration)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: EFS consumer migration](#phase-5-efs-consumer-migration)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Verify and document](#phase-6-verify-and-document)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. Do the four new variables get defaults, or are they required?](#1-do-the-four-new-variables-get-defaults-or-are-they-required)
  - [2. What goes in the shared var-file, and do we consolidate the test bucket?](#2-what-goes-in-the-shared-var-file-and-do-we-consolidate-the-test-bucket)
  - [3. How do EKS/EFS fixtures move?](#3-how-do-eksefs-fixtures-move)
  - [4. Phasing granularity?](#4-phasing-granularity)
  - [5. Is the assume-role session name a literal or a variable?](#5-is-the-assume-role-session-name-a-literal-or-a-variable)
  - [6. The var-file's "undeclared variable" warning for producer-only modules](#6-the-var-files-undeclared-variable-warning-for-producer-only-modules)
- [References](#references)
<!--toc:end-->

## Objective

Migrate every module's `data.terraform_remote_state` lookup from the simplified
single-account shape to the production Terragrunt multi-account shape:
account-scoped state key, a distinct state-bucket region, and a cross-account
`assume_role` block. Keep the LocalStack test suites green by centralizing the
Terragrunt-supplied test inputs in one shared var-file and by seeding the
fixtures at the account-scoped key.

**Implements:** INV-0005 (resolved: 1a declare in the ten consumers, 2a two
distinct region variables, 3a plan stubs unchanged, 4 the "common consumed
inputs" var-file + expanded `reference-vpc`, 5a spike first).

## Scope

### In Scope

- The **four new variables** (`account_name`, `account_id`,
  `remote_state_bucket_region`, `deploy_role_name`) declared in the **ten
  remote-state consumers** and wired into their `terraform_remote_state`
  `config` block (account-scoped key + `assume_role`).
- The shared **`test/fixtures/terragrunt-inputs.tfvars`** and its wiring into the
  `just tf test*` recipes.
- The **expanded `reference-vpc` fixture** (account-scoped VPC key + the two new
  inputs) and the **RDS composing fixtures** that build on it.
- The **EKS + EFS bespoke `fixtures/setup`** account-key updates (their state
  seeders must match the account-scoped read).
- The four new **`variable` declarations** added to each consumer's plan suites
  so the `config` interpolations resolve (values from the var-file).

### Out of Scope

- **The 158 `override_data` stub *outputs*** — `override_data` bypasses the S3
  backend, so key/region/`assume_role` are irrelevant at plan time (INV-0005 3a).
  Only the four `variable` declarations are added; stub output maps are untouched.
- **The real `network/vpc` + `network/vpc-lookup` producer state keys** — in
  Terragrunt the *storage* key is set by the live backend config, not the module.
  `vpc-lookup` has no lookup to migrate; its own key is a follow-up (INV-0005 4).
- **EKS/EFS adoption of `reference-vpc`** — that consolidation is DESIGN-0015
  (addendum) / DESIGN-0017; here their *existing* bespoke fixtures are only
  account-scoped (Open Question 3).
- **Any module runtime behavior** — this changes only where/how remote state is
  *read*, not what the modules build.

## The uniform transformation

All ten consumers carry the identical block today (only the `key` middle segment
and the data-source name differ):

```hcl
config = {
  bucket         = var.remote_state_bucket
  key            = "${var.region}/<shape>/terraform.tfstate"
  region         = var.region
  use_path_style = true
}
```

Every one becomes:

```hcl
config = {
  bucket         = var.remote_state_bucket
  key            = "${var.account_name}/${var.region}/<shape>/terraform.tfstate"
  region         = var.remote_state_bucket_region
  use_path_style = true
  assume_role = {
    role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
    session_name = "Deploy-Tf"
  }
}
```

The four `<shape>` values (correcting INV-0005 F1/F4 — there are **four**, not
three; `eks/managed-node-group` reads the **eks** state, not vpc):

| Shape | Consumers |
|-------|-----------|
| `vpc/${vpc_name}` | `eks/cluster`, `rds/serverless`, `rds/cluster`, `rds/instance`, `efs/filesystem` |
| `eks/${cluster_name}` | `eks/managed-node-group`, `eks/addons`, `eks/pod-identity-access` |
| `rds/${target_dir}/${target_identifier}` | `rds/proxy` |
| `rds/cluster/${cluster_identifier}` | `rds/read-replica` |

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its tasks are
checked off and its success criteria are met.

---

### Phase 1: Spike the account-scoped read on LocalStack

Prove the one unproven mechanic (INV-0005 5a) before touching the fleet: a
`terraform_remote_state` S3 backend with an `assume_role` block, reading an
account-scoped key, against LocalStack. Throwaway — deleted at the end of the
phase.

#### Tasks

- [ ] In a scratch dir, seed an S3 object at
  `${account_name}/${region}/vpc/${vpc_name}/terraform.tfstate` on LocalStack
  (`account_id = "000000000000"`, any `deploy_role_name`).
- [ ] Read it back through a `data.terraform_remote_state` with the full
  `assume_role` + `use_path_style` config, asserting an output resolves.
- [ ] Confirm the backend's STS `AssumeRole` + S3 GET both route to LocalStack
  via `AWS_ENDPOINT_URL` (Community tier — no token needed).
- [ ] Record the result (works / needs-endpoint-tweak) in the doc; delete the
  scratch dir.

#### Success Criteria

- A LocalStack apply reads an account-scoped key through an `assume_role` S3
  backend and surfaces the seeded output.
- Any endpoint/credential wrinkle (e.g. STS routing) is documented so Phases 2–5
  inherit a known-good backend shape.

---

### Phase 2: Shared foundation

Establish the shared test input and the account-scoped producer key, plus the
recipe wiring, so every later phase plugs into them.

#### Tasks

- [ ] Create **`test/fixtures/terragrunt-inputs.tfvars`** with the shared
  constants (`account_name`, `account_id`, `remote_state_bucket_region`,
  `deploy_role_name`, and `region` — see Open Question 2 for `remote_state_bucket`).
- [ ] Wire `-var-file` into the `_tf-test`, `_tf-test-localstack`, and
  `_tf-test-localstack-pro` recipes in the `justfile` (relative
  `../../../test/fixtures/terragrunt-inputs.tfvars` from the module dir).
- [ ] Expand **`test/fixtures/reference-vpc`**: add `account_name` +
  `remote_state_bucket_region` inputs; seed the VPC state at
  `${account_name}/${region}/vpc/${vpc_name}/terraform.tfstate`; re-emit the two
  new values as outputs for composing fixtures.
- [ ] Define the canonical four-variable block (with descriptions, `nullable`,
  and default policy per Open Question 1) as the snippet Phases 3–5 copy into
  each consumer's `variables.tf`.

#### Success Criteria

- `just tf test-localstack rds/serverless` still green with the expanded
  `reference-vpc` seeding the account-scoped key and the module still reading the
  region-scoped key (i.e. the fixture change is backward-compatible until the
  consumer is migrated in Phase 3 — or Phase 2 + the `rds/serverless` slice of
  Phase 3 land together; see Open Question 4).
- The var-file resolves for a migrated sample and the recipes pass it without
  path errors.

---

### Phase 3: RDS consumer migration

The five RDS consumers already source `reference-vpc` (IMPL-0014), so their
fixture side is nearly free once Phase 2 lands.

#### Tasks

- [ ] `rds/serverless`, `rds/cluster`, `rds/instance`: add the four `variable`
  declarations; rewrite the `data.terraform_remote_state.vpc` block to the
  account-scoped key + `assume_role`.
- [ ] `rds/proxy`: same on `data.terraform_remote_state.target`; update
  `fixtures/db` to seed the target state at the account-scoped key.
- [ ] `rds/read-replica`: same on `data.terraform_remote_state.rds_cluster`;
  update `fixtures/cluster` to seed the cluster state at the account-scoped key
  (it already composes `reference-vpc` for the VPC side).
- [ ] Add the four `variable` declarations to every RDS plan suite (serverless 6,
  cluster 5, instance 6, proxy 5, read-replica 3 files) — declarations only; the
  `override_data` output maps are untouched (3a); values come from the var-file.

#### Success Criteria

- `just tf test rds/{serverless,cluster,instance,proxy,read-replica}` green (plan).
- `just tf test-localstack rds/serverless` green (Community apply).
- `just tf test-localstack-pro rds/{cluster,instance,proxy,read-replica}` green
  (named-volume Pro apply) — the account-scoped read resolves against the
  account-scoped seed.

---

### Phase 4: EKS consumer migration

The four EKS consumers still use bespoke `fixtures/setup` (not `reference-vpc`);
this phase account-scopes their source blocks **and** their bespoke seeders
(Open Question 3 — minimal account-prefix, not `reference-vpc` adoption).

#### Tasks

- [ ] `eks/cluster`: add the four variables; rewrite `data.terraform_remote_state.vpc`
  to the account-scoped key + `assume_role`; account-scope its `fixtures/setup`
  VPC seed.
- [ ] `eks/managed-node-group`, `eks/addons`, `eks/pod-identity-access`: add the
  four variables; rewrite `data.terraform_remote_state.eks` to the account-scoped
  key + `assume_role`; account-scope their `fixtures/setup` EKS-state seeds.
- [ ] Add the four `variable` declarations to every EKS plan suite (cluster 3,
  managed-node-group 3, addons 4, pod-identity-access 4 files); stub outputs
  untouched (3a).

#### Success Criteria

- `just tf test eks/{cluster,managed-node-group,addons,pod-identity-access}`
  green (plan).
- `just tf test-localstack eks/{cluster,managed-node-group,addons,pod-identity-access}`
  green (Community apply) — each account-scoped read resolves against its
  account-scoped seed.

---

### Phase 5: EFS consumer migration

The single EFS consumer, same pattern as an EKS vpc consumer.

#### Tasks

- [ ] `efs/filesystem`: add the four variables; rewrite
  `data.terraform_remote_state.vpc` to the account-scoped key + `assume_role`;
  account-scope its `fixtures/setup` VPC seed.
- [ ] Add the four `variable` declarations to the EFS plan suite (9 files);
  stub outputs untouched (3a).

#### Success Criteria

- `just tf test efs/filesystem` green (plan).
- `just tf test-localstack efs/filesystem` green (Community apply).

---

### Phase 6: Verify and document

#### Tasks

- [ ] `just tf all <m>` for all ten consumers; `just tf validate|lint|fmt` for the
  two producer-only modules (`network/vpc-lookup`, and confirm no regression).
- [ ] Grep-confirm: zero consumer blocks still use a region-scoped key or omit
  `assume_role`; all seeded fixture keys carry the `${account_name}/` prefix.
- [ ] Confirm `terraform-docs` regen for the ten consumers (four new inputs land
  in each `USAGE.md`).
- [ ] Update the affected `tests-localstack*/FINDINGS.md` to note the
  account-scoped key + the shared var-file.
- [ ] Update `CLAUDE.md`: record the remote-state contract change + the shared
  var-file.
- [ ] Flip INV-0005 → Concluded and IMPL-0015 → Completed; `docz update`.

#### Success Criteria

- Every consumer's gates are green (plan for all ten; Community/Pro applies where
  runnable, else plan-verified + flagged).
- Every `data.terraform_remote_state` block in `modules/` is account-scoped with
  an `assume_role`; every state-seeding fixture matches; `CLAUDE.md` +
  `USAGE.md`s reflect the shipped state.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `test/fixtures/terragrunt-inputs.tfvars` | Create | Shared Terragrunt test inputs |
| `test/fixtures/reference-vpc/{variables,main,outputs}.tf` | Modify | `account_name` + `remote_state_bucket_region`; account-scoped key; new outputs |
| `justfile` | Modify | `-var-file` into the three `_tf-test*` recipes |
| `modules/{eks/cluster,eks/managed-node-group,eks/addons,eks/pod-identity-access,rds/serverless,rds/cluster,rds/instance,rds/proxy,rds/read-replica,efs/filesystem}/variables.tf` | Modify | Four new `variable` declarations (×10) |
| `modules/**/{data,main}.tf` (10 consumers) | Modify | Account-scoped key + `assume_role` block (×10) |
| `modules/{eks/*,efs/filesystem}/tests-localstack/fixtures/setup/main.tf` | Modify | Account-scope the bespoke seeders (×5) |
| `modules/rds/{proxy/fixtures/db,read-replica/fixtures/cluster}/main.tf` | Modify | Account-scope the composed seeders (×2) |
| `modules/**/tests/*.tftest.hcl` (all ten consumers) | Modify | Four `variable` declarations; override maps untouched |
| `CLAUDE.md`, `docs/investigation/0005-*.md` | Modify | Record shipped state; flip statuses |

## Testing Plan

- **Plan gate (`just tf test <m>`):** all ten consumers stay green; the four new
  vars resolve from the var-file, `override_data` maps unchanged.
- **Community apply (`just tf test-localstack <m>`):** `rds/serverless`, the four
  EKS modules, `efs/filesystem` — the account-scoped read resolves against the
  account-scoped seed through `assume_role`.
- **Pro apply (`just tf test-localstack-pro rds/{cluster,instance,proxy,read-replica}`):**
  named-volume LocalStack Pro; account-scoped reads green.
- **Fidelity grep:** zero region-scoped consumer keys, zero missing `assume_role`,
  every seeded fixture key account-prefixed.
- **Spike (Phase 1):** the standalone assume-role read is the go/no-go gate.

## Dependencies

- **INV-0005 resolutions** (1a / 2a / 3a / 4 / 5a) are the decisions of record.
- **Phase 1 blocks Phases 2–5** — the spike must pass first (5a).
- **Phase 2 blocks Phases 3–5** — the var-file + expanded `reference-vpc` +
  recipe wiring underpin every consumer.
- **LocalStack Pro + named volume** for the RDS Pro applies (macOS `initdb`
  gotcha — see the modules' `FINDINGS.md`).
- **IMPL-0014** — the shared `reference-vpc` fixture this expands.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
> (Reply e.g. "1a, 2a, 3a, 4a, 5a, 6a".)

### 1. Do the four new variables get defaults, or are they required?

- **a — Required (no default, `nullable = false`).** *(recommended)* Terragrunt
  always injects them in production; tests supply them via the var-file. Fail-fast
  if a caller forgets one; no silent-wrong-default risk.
- **b — Nullable with test-friendly defaults.** Tests run without the var-file,
  but production could silently use a placeholder account/role.
- **other.**

### 2. What goes in the shared var-file, and do we consolidate the test bucket?

- **a — The four new vars plus `region`; `remote_state_bucket` stays per-suite.**
  *(recommended)* Bucket names already differ per module; keep them local, put
  only the truly-shared constants in the file. Least churn.
- **b — Also put `remote_state_bucket` in the file and consolidate every suite
  onto one shared test bucket.** Most Terragrunt-faithful (prod has one state
  bucket), but touches every fixture + test that names a bucket.
- **other.**

### 3. How do EKS/EFS fixtures move?

- **a — Account-scope the existing bespoke `fixtures/setup` only.** *(recommended)*
  Smallest change that keeps their applies green; defer `reference-vpc` adoption
  to its own effort (DESIGN-0015 addendum / DESIGN-0017).
- **b — Adopt `reference-vpc` and account-scope in one move.** Consolidates the
  fixtures now, but folds a separate design's scope into this migration.
- **other.**

### 4. Phasing granularity?

- **a — By consumer group, each its own commit + gate (Phase 2 → RDS → EKS → EFS).**
  *(recommended)* Producer/consumer pairs are independent per group, so each group
  migrates safely on its own; smaller reviewable units. Phase 2 lands with the
  first RDS slice so `reference-vpc` and its first consumer move together.
- **b — One coordinated change across all ten.** Matches INV-0005's "one
  coordinated change" wording, but a large, hard-to-review diff.
- **other.**

### 5. Is the assume-role session name a literal or a variable?

- **a — Hard-code the literal `"Deploy-Tf"`.** *(recommended)* It matches the
  production block, does not vary per environment, and adding a fifth variable
  for a constant string is noise.
- **b — A `deploy_session_name` variable.** Maximum flexibility; one more input on
  every consumer for a value that never changes.
- **other.**

### 6. The var-file's "undeclared variable" warning for producer-only modules

Running `just tf test network/vpc-lookup` (no remote-state lookup, so no new
vars) with the global `-var-file` prints a harmless Terraform *warning* per
undeclared variable.

- **a — Accept the warning.** *(recommended)* It is non-fatal, tests still pass,
  and it disappears if such a module ever gains a lookup. Simplest recipe.
- **b — Only pass `-var-file` for the ten consumers** via a recipe conditional.
  Cleaner output, more `justfile` logic to maintain.
- **other.**

## References

- INV-0005 — the investigation this implements (the terragrunt-faithful block,
  the four new vars, the var-file + expanded `reference-vpc` decision).
- IMPL-0014 / DESIGN-0016 — the shared `reference-vpc` fixture this expands.
- ADR-0001 — cross-module data flows through last-known-good remote state.
- INV-0004 — the VPC remote-state contract.
- `modules/eks/cluster/data.tf` — the canonical current remote-state block.
