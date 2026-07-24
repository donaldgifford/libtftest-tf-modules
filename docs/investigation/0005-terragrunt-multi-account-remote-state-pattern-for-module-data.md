---
id: INV-0005
title: "Terragrunt multi-account remote-state pattern for module data lookups"
status: Open
author: Donald Gifford
created: 2026-07-24
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0005: Terragrunt multi-account remote-state pattern for module data lookups

**Status:** Open
**Author:** Donald Gifford
**Date:** 2026-07-24

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Findings](#findings)
  - [F1 — Ten modules carry a remote-state lookup](#f1--ten-modules-carry-a-remote-state-lookup)
  - [F2 — Current block vs. the terragrunt-faithful block](#f2--current-block-vs-the-terragrunt-faithful-block)
  - [F3 — Variable gap: four new inputs, zero declared today](#f3--variable-gap-four-new-inputs-zero-declared-today)
  - [F4 — Three key shapes, all need the account prefix](#f4--three-key-shapes-all-need-the-account-prefix)
  - [F5 — The LocalStack test surface is the real blast radius](#f5--the-localstack-test-surface-is-the-real-blast-radius)
  - [F6 — Cross-account assume-role in a remote-state backend under LocalStack](#f6--cross-account-assume-role-in-a-remote-state-backend-under-localstack)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Open Questions](#open-questions)
  - [1. Which modules declare the four new variables?](#1-which-modules-declare-the-four-new-variables)
  - [2. How do we model the state-bucket region vs. the deploy region?](#2-how-do-we-model-the-state-bucket-region-vs-the-deploy-region)
  - [3. Do the plan-time override stubs change at all?](#3-do-the-plan-time-override-stubs-change-at-all)
  - [4. Where does the account-scoped producer key get updated?](#4-where-does-the-account-scoped-producer-key-get-updated)
  - [5. Do we spike cross-account assume-role under LocalStack first?](#5-do-we-spike-cross-account-assume-role-under-localstack-first)
- [References](#references)
<!--toc:end-->

## Question

Our real deployment runs **Terragrunt in a multi-account "live" structure**.
Terragrunt supplies a fixed set of inputs to every module via `include`s, so the
production `terraform_remote_state` block looks like:

```hcl
data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.account_name}/${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.remote_state_bucket_region
    use_path_style = true
    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}
```

The modules in this repo currently use a **simplified, single-account** block
(no `account_name` key segment, `region` reused for the bucket, no
`assume_role`). **What is the full blast radius of migrating every module's
remote-state lookup to the terragrunt-faithful shape, and what does it do to our
LocalStack test fixtures?**

## Hypothesis

Every module with a `terraform_remote_state` lookup needs **four new variables**
(`remote_state_bucket_region`, `account_name`, `account_id`, `deploy_role_name`)
plus a rewrite of the `config` block. Because Terragrunt injects these inputs
globally (whether a given module consumes them or not), the *module-side* change
is mechanical and low-risk. The **real cost is test-side**: the shared
`reference-vpc` fixture, every apply fixture, and all 68+ plan-time
`override_data` stubs seed state at the *region-scoped* key and provide only the
old variable set — they must all move to the account-scoped key and gain the new
inputs, or the lookups will 404 at plan/apply.

## Context

The single-account key shape was a deliberate simplification for LocalStack
testing (ADR-0001: cross-module data flows through last-known-good remote state;
INV-0004: the two-output VPC contract). It was never meant to match production
Terragrunt — it just had to exercise the *consumption* contract. Now that the
fleet is broadly built and the shared `reference-vpc` fixture (IMPL-0014) has
just standardized the test-side state seeding, this is the moment to decide
whether the modules should carry the production-faithful remote-state shape.

**Triggered by:** user report of the real Terragrunt live-repo remote-state
pattern; follow-up to INV-0004 / IMPL-0014.

## Approach

1. Enumerate every `data "terraform_remote_state"` in `modules/`.
2. Diff the current `config` block against the terragrunt-faithful block.
3. Count the variable gap (which of the six inputs already exist vs. are new).
4. Enumerate the distinct state **key shapes** (vpc, rds-target, rds-cluster).
5. Trace the ripple into the test surface (fixtures + `override_data` stubs).
6. Sanity-check whether LocalStack honors `assume_role` inside a remote-state
   backend config.

## Findings

### F1 — Ten modules carry a remote-state lookup

`grep -rl 'data "terraform_remote_state"' modules/`:

| Module | Lookup(s) | Reads |
|--------|-----------|-------|
| `network/vpc-lookup` | — | *producer* (writes the state; no lookup) |
| `eks/cluster` | `vpc` | `vpc_id`, `private_eks_subnet_ids` |
| `eks/managed-node-group` | `vpc` | `vpc_id`, `private_subnet_ids` |
| `eks/addons` | (cluster) | cluster remote state |
| `eks/pod-identity-access` | (cluster) | cluster remote state |
| `rds/serverless` | `vpc` | `vpc_id`, `private_subnet_ids` |
| `rds/cluster` | `vpc` | `vpc_id`, `private_subnet_ids` |
| `rds/instance` | `vpc` | `vpc_id`, `private_subnet_ids` |
| `rds/proxy` | `target` | the target's proxy-composition outputs |
| `rds/read-replica` | `rds_cluster` | the cluster's consumer set |
| `efs/filesystem` | `vpc` | `vpc_id`, `private_subnet_ids` |

Ten consumer modules (the eks `addons`/`pod-identity-access` read a *cluster*
state, not vpc). The pattern is fleet-wide, not vpc-specific — **every** module
that will ever read remote state inherits this decision.

### F2 — Current block vs. the terragrunt-faithful block

Current (`modules/eks/cluster/data.tf`, canonical):

```hcl
config = {
  bucket         = var.remote_state_bucket
  key            = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
  region         = var.region
  use_path_style = true
}
```

Three concrete deltas to reach the production shape:

1. **Key gains an `${var.account_name}/` prefix** →
   `${account_name}/${region}/vpc/${vpc_name}/terraform.tfstate`.
2. **`region` splits into two concepts** — the *deploy* region (`var.region`,
   used in the key) and the *state-bucket* region
   (`var.remote_state_bucket_region`, used for the backend's `region`). Today
   they are conflated.
3. **A new `assume_role` block** — `role_arn =
   arn:aws:iam::${account_id}:role/${deploy_role_name}`, `session_name =
   "Deploy-Tf"` — so the read cross-account-assumes into the target account.

### F3 — Variable gap: four new inputs, zero declared today

`grep -rl 'variable "<name>"' modules/`:

| Variable | Declared in | Status |
|----------|-------------|--------|
| `remote_state_bucket` | 17 modules | exists |
| `region` | 20 modules | exists |
| `vpc_name` | 10 modules | exists |
| `remote_state_bucket_region` | **0** | **new** |
| `account_name` | **0** | **new** |
| `account_id` | **0** | **new** |
| `deploy_role_name` | **0** | **new** |

The four new inputs are declared nowhere. Terragrunt would supply them as
`TF_VAR_*` regardless, but Terraform only *uses* a value if the module declares
the `variable` — so each of the ten consumers must add the four declarations for
the interpolations to resolve.

### F4 — Three key shapes, all need the account prefix

The remote-state keys in the fleet:

```text
${region}/vpc/${vpc_name}/terraform.tfstate                      # 6 vpc consumers
${region}/rds/${target_dir}/${target_identifier}/terraform.tfstate  # rds/proxy
${region}/rds/cluster/${cluster_identifier}/terraform.tfstate    # rds/read-replica
```

All three gain the same `${account_name}/` prefix. The producer side matters
too: `network/vpc-lookup` (and the future `network/vpc`) publishes at
`${region}/vpc/${name}/…`; if consumers read `${account_name}/${region}/…` the
**producer's published key must move in lockstep** or every read 404s. This is a
contract change, not just a consumer edit.

### F5 — The LocalStack test surface is the real blast radius

The module edits are ~10 files. The test edits are far larger and were *just*
standardized by IMPL-0014:

- **`test/fixtures/reference-vpc`** seeds at `${region}/vpc/${vpc_name}/…` and
  takes `remote_state_bucket` / `vpc_name` / `region`. It would need the
  `${account_name}/` key prefix and (optionally) `account_name` input.
- **Every apply fixture** (`rds/{serverless,cluster,instance}` via the shared
  fixture; `rds/proxy` `fixtures/db`; `rds/read-replica` `fixtures/cluster`)
  passes the old three inputs and seeds region-scoped keys.
- **68 plan-time `override_data` stubs** across `rds/{serverless,cluster,instance}`
  override `data.terraform_remote_state.vpc`. `override_data` replaces the data
  source's *outputs*, so it is **insensitive to the key/region/assume_role** — a
  plan override does not actually read S3. **The plan suites likely need only the
  four new `variable` declarations (so interpolations resolve), not stub
  changes.** The apply suites are where the key + assume_role must line up.
- LocalStack is single-account (`000000000000`); `account_name` is a free-form
  label and `account_id` would be `000000000000` in tests, with
  `deploy_role_name` any role STS will vend.

### F6 — Cross-account assume-role in a remote-state backend under LocalStack

The S3 backend of a `terraform_remote_state` data source supports an
`assume_role` object; Terraform resolves it via STS before the S3 GET.
LocalStack's STS `AssumeRole` returns synthetic credentials for any role ARN and
Community S3 honors them, so an account-scoped read *should* work against
LocalStack with `account_id = "000000000000"`. **This is the one item that wants
a spike** (a throwaway apply that seeds `${account_name}/…` and reads it back
through an `assume_role` backend) before committing the fleet.

## Conclusion

**Answer: Yes — the migration is mechanical on the module side (10 files, 4 new
variables, one rewritten block each) but its center of gravity is the test
surface and the producer/consumer key contract.** The plan suites most likely
need only the four `variable` declarations (override_data bypasses the backend);
the apply fixtures and the `reference-vpc` producer key are the real work, and
`assume_role`-under-LocalStack deserves a 30-minute spike first.

## Recommendation

Promote this to a DESIGN. Per the Q4 resolution, **two shared test artifacts**
carry the migration and keep the producer/consumer keys from drifting:

- **`test/fixtures/terragrunt-inputs.tfvars` — the shared inputs file.** A single
  var-file holding the six terragrunt-supplied constants (`account_name`,
  `account_id`, `region`, `remote_state_bucket`, `remote_state_bucket_region`,
  `deploy_role_name`), wired into the `just tf test*` recipes so every suite
  reads them without repeating a `variables {}` block. This is the "common
  consumed inputs" the fleet's tests share; it also satisfies the plan-suite half
  of 3a (the four new vars come from here, not per-file). A `.tfvars` — not a
  module — because these are constants (see Q4).
- **An expanded `reference-vpc` fixture.** Grow the *existing* shared fixture to
  take `account_name` (+ `remote_state_bucket_region`), seed the **account-scoped**
  key `${account_name}/${region}/vpc/${vpc_name}/…`, and re-emit those values so
  the composing fixtures (`rds/proxy` `fixtures/db`, `rds/read-replica`
  `fixtures/cluster`) stay in lockstep. Extend it, do not fork it, and do not add
  a separate constants-only module.

Sequence: (1) spike cross-account `assume_role` + the account-scoped key against
LocalStack; (2) add the shared `.tfvars` **and** expand `reference-vpc` to seed
the account-scoped key; (3) roll the four variables + the block rewrite across the
ten consumers; (4) reconcile the apply fixtures onto the shared inputs; (5) add
the four `variable` decls to the plan suites (values supplied by the `.tfvars`).
Land it as one coordinated change so the producer/consumer keys never diverge.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
> (Reply e.g. "1a, 2a, 3b".)
>
> **Resolved 2026-07-24 — 1a, 2a, 3a, 5a; Q4 → the "common consumed inputs"
> variant below.** Declare the four new inputs only in the ten remote-state
> consumers (1a); model the state-bucket region and the deploy region as two
> distinct variables (2a); the plan suites gain only the four `variable`
> declarations, stub outputs untouched (3a); spike cross-account assume-role
> under LocalStack before touching the fleet (5a).
>
> **Q4 resolution — centralize the terragrunt test inputs; do it by *growing
> what we have*, not by adding a constants-only module.** The instinct is
> right and **not an anti-pattern as a goal** — a single source for the six
> terragrunt-supplied values (`account_name`, `account_id`, `region`,
> `remote_state_bucket`, `remote_state_bucket_region`, `deploy_role_name`)
> keeps the consumer's remote-state *key* and the fixture's *seeded* key from
> drifting, which is the whole failure mode 4 was worried about. The mechanism:
>
> - **Do — a shared `-var-file`** (e.g. `test/fixtures/terragrunt-inputs.tfvars`)
>   holding the six constants, wired into the `just tf test*` recipes. It sets
>   the vars globally for the module-under-test runs, and each `run "setup"`
>   forwards `account_name` / `region` / bucket into the fixture. This also
>   *simplifies* 3a — the plan suites read the new vars from the var-file
>   instead of repeating them in every `variables {}` block.
> - **Do — extend the existing shared `reference-vpc` fixture** to take
>   `account_name` (+ `remote_state_bucket_region`) and seed the
>   **account-scoped** key `${account_name}/${region}/vpc/${vpc_name}/…`,
>   re-emitting those values so composing fixtures stay in lockstep. It already
>   *is* the "common consumed test fixture"; grow it rather than fork it.
> - **Avoid — a brand-new module whose only job is to echo constant account
>   values.** A fixture that instantiates nothing and computes nothing is
>   indirection for its own sake — *that* part would be the anti-pattern.
>   `reference-vpc` earns a module because it creates resources and computes
>   real outputs (subnet IDs, gateway IDs); a "here are your six strings"
>   module does not — a `.tfvars` file is the honest shape for constants.
>
> This subsumes the original 4a (reference-vpc is where the account-scoped
> producer key lands) and still defers the real `network/vpc` + `vpc-lookup`
> producer keys to a follow-up INV/DESIGN.

### 1. Which modules declare the four new variables?

- **a — Only the ten remote-state consumers.** *(recommended)* Declare where
  used; Terragrunt still injects globally, and undeclared `TF_VAR_*` are ignored
  by Terraform. Narrow, honest interfaces.
- **b — Every module in the fleet.** Uniform surface ("always present whether
  consumed or not") at the cost of dead variables in modules with no lookup.
- **other.**

### 2. How do we model the state-bucket region vs. the deploy region?

- **a — Two distinct variables** (`region` = deploy region in the key;
  `remote_state_bucket_region` = backend region). *(recommended)* Matches the
  production block exactly.
- **b — One `region`, default the bucket region to it** via a local
  (`coalesce(var.remote_state_bucket_region, var.region)`). Fewer required
  inputs, but diverges from the terragrunt include shape.
- **other.**

### 3. Do the plan-time override stubs change at all?

- **a — Add only the four `variable` declarations; leave the stub outputs
  untouched.** *(recommended)* `override_data` replaces outputs and never hits
  the backend, so key/region/assume_role are irrelevant at plan time. Verify
  once, then apply fleet-wide.
- **b — Also rewrite the stub keys/regions for realism.** Belt-and-suspenders,
  but pure churn (the values are never read).
- **other.**

### 4. Where does the account-scoped producer key get updated?

- **a — Update `reference-vpc` (test producer) now; write a follow-up INV/DESIGN
  for the real `network/vpc` + `vpc-lookup` producer keys.** *(recommended)*
  Keeps this change test-consistent without prematurely designing the greenfield
  `vpc` module.
- **b — Update `vpc-lookup` producer + `reference-vpc` together in this change.**
  One contract move, larger diff.
- **other.**

### 5. Do we spike cross-account assume-role under LocalStack first?

- **a — Yes, a throwaway spike first** (seed `${account_name}/…`, read via an
  `assume_role` S3 backend against LocalStack). *(recommended)* De-risks the one
  unproven mechanic before touching ten modules.
- **b — No, assume it works** (STS AssumeRole is well-supported) and fix forward
  if the apply suites fail.
- **other.**

## References

- ADR-0001 — cross-module data flows through last-known-good remote state.
- INV-0004 — the VPC remote-state contract (two-output minimum).
- IMPL-0014 / DESIGN-0016 — the shared `reference-vpc` fixture + nine-output
  seeding (the test surface this touches).
- `modules/eks/cluster/data.tf` — the canonical current remote-state block.
