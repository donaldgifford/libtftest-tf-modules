---
id: IMPL-0014
title: "RDS test-fixture vpc-lookup fidelity"
status: In Progress
author: Donald Gifford
created: 2026-07-23
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0014: RDS test-fixture vpc-lookup fidelity

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-07-23

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Shared reference-VPC fixture](#phase-1-shared-reference-vpc-fixture)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Adopt the shared fixture in the direct consumers](#phase-2-adopt-the-shared-fixture-in-the-direct-consumers)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Special cases — proxy and read-replica](#phase-3-special-cases--proxy-and-read-replica)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Plan-time override stubs](#phase-4-plan-time-override-stubs)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Verify and document](#phase-5-verify-and-document)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. How deeply should the special-case fixtures adopt the shared fixture?](#1-how-deeply-should-the-special-case-fixtures-adopt-the-shared-fixture)
  - [2. Where should the shared reference fixture live?](#2-where-should-the-shared-reference-fixture-live)
  - [3. How much routing/gateway detail should the shared fixture create?](#3-how-much-routinggateway-detail-should-the-shared-fixture-create)
  - [4. Ship as one PR, or split the shared fixture into a precursor?](#4-ship-as-one-pr-or-split-the-shared-fixture-into-a-precursor)
  - [5. How strongly should the apply suites assert the fixture wiring?](#5-how-strongly-should-the-apply-suites-assert-the-fixture-wiring)
- [References](#references)
<!--toc:end-->

## Objective

Make every RDS test fixture that stubs the VPC remote state a faithful
`vpc-lookup` stand-in: the three-tier `Network`-tagged topology plus the full
nine-output contract, sourced from a single shared fixture rather than the
current per-module, `Tier`-tagged, two-output stubs. No RDS module source
changes — the modules keep reading only `vpc_id` + `private_subnet_ids`.

**Implements:** DESIGN-0016 (resolved: 1a shared reference fixture, 2a full
nine-output contract, 3a plan stubs mirrored, 4b both proxy and read-replica in
scope, 5a three AZs).

## Scope

### In Scope

- A new shared `test/fixtures/reference-vpc` module (the reference topology +
  full-contract state seeder) — built here, later reused by the EKS
  (DESIGN-0015 addendum) and EFS (DESIGN-0017) slices.
- Repointing the five RDS fixtures at it: `serverless`, `cluster`, `instance`
  (direct `data.terraform_remote_state.vpc` consumers) and `proxy`,
  `read-replica` (the special cases, per decision 4b).
- Mirroring the plan-time `override_data` VPC stubs to the nine-key schema
  across the `serverless` / `cluster` / `instance` plan suites.

### Out of Scope

- **Any RDS module source change** — this is test-fidelity only. The modules
  still read `vpc_id` + `private_subnet_ids`.
- **Instantiating `vpc-lookup`** — the shared fixture *maps to* its output shape;
  it does not run the producer module.
- **The EKS and EFS fixture slices** — DESIGN-0015 addendum / DESIGN-0017; they
  adopt the same shared fixture in follow-up work.
- **The non-VPC seeded states** the special-case fixtures also write (proxy's
  target state, read-replica's cluster state) — those are other producers'
  contracts and are left as-is.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its tasks
are checked off and its success criteria are met.

---

### Phase 1: Shared reference-VPC fixture

Build `test/fixtures/reference-vpc` — the single source of truth for the
reference topology + full-contract seeded state. Modelled on the existing
`modules/network/vpc-lookup/tests-localstack/fixtures/setup/main.tf`, which
already stands up this exact topology.

#### Tasks

- [x] Create the module skeleton: `versions.tf` (`required_version >= 1.1`, aws
  `~> 6.2`), `variables.tf`, `main.tf`, `outputs.tf`, `.tflint.hcl`.
- [x] Inputs: `remote_state_bucket`, `vpc_name`, `region` (required); `vpc_cidr`
  (default `"10.0.0.0/16"`); `az_letters` (default `["a", "b", "c"]` → three AZs
  per 5a).
- [x] Three subnet tiers × three AZs, non-overlapping /24s:
  `public` (`Network = "Public"` + `kubernetes.io/role/elb = "1"`),
  `private` (`Network = "Private"` + `kubernetes.io/role/internal-elb = "1"`),
  `private_eks` (`Network = "Private EKS"`).
- [x] Gateways/routing so the network-fact outputs are backed by real resources:
  `aws_internet_gateway` + `aws_eip` + one `aws_nat_gateway` (in `public[0]`);
  public route table → IGW, private route table → NAT, with associations.
- [x] `aws_s3_bucket` (`force_destroy = true`) + `aws_s3_object.vpc_state`
  seeding the **full nine-output** contract at
  `${region}/vpc/${vpc_name}/terraform.tfstate`, every value computed from the
  resources above.
- [x] Outputs: the nine contract values **plus** `bucket_name` (so composing
  fixtures can write additional state into the same bucket — see Phase 3).
- [x] `terraform fmt` + `tflint` clean; no `USAGE.md` for a test fixture (matches
  the existing `tests-localstack/fixtures/setup` convention).

#### Success Criteria

- `terraform init -backend=false && terraform validate`, `terraform fmt -check`,
  and `tflint` all pass for the new module.
- A real Community LocalStack apply (`SERVICES=ec2,s3,sts`, token-free image)
  succeeds; the seeded S3 object parses and its `outputs` map contains all nine
  keys.
- The three subnet tiers are pairwise disjoint, each spans three AZs, and the
  `nat_gateway_ids` / `route_table_ids` / `internet_gateway_id` outputs are
  non-empty.

---

### Phase 2: Adopt the shared fixture in the direct consumers

Repoint the three pure VPC-seeding fixtures (`serverless`, `cluster`,
`instance`) at the shared module and delete their bespoke `fixtures/setup`
directories.

#### Tasks

- [x] `rds/serverless`: point `run "setup"` in
  `tests-localstack/apply_localstack.tftest.hcl` `module.source` at
  `../../../test/fixtures/reference-vpc` (relative to the module root — verify
  depth); delete `tests-localstack/fixtures/setup/`.
- [x] `rds/cluster`: repoint `tests-localstack-pro/apply_pro.tftest.hcl:77`
  `module.source`; delete `tests-localstack-pro/fixtures/setup/`.
- [x] `rds/instance`: repoint `tests-localstack-pro/apply_pro.tftest.hcl:92`
  `module.source`; delete `tests-localstack-pro/fixtures/setup/`.
- [x] Confirm the `setup` run still passes `remote_state_bucket` / `vpc_name` /
  `region` (the shared fixture's input names match the deleted fixtures').

#### Success Criteria

- `just tf test-localstack rds/serverless` green (Community apply) — the module's
  RDS resources bind `private_subnet_ids` from the shared fixture.
- `just tf test-localstack-pro rds/cluster` and `rds/instance` green against
  LocalStack Pro (named-volume + `engine_version = 16` pins, unchanged) — or, if
  Pro is unavailable in the session, plan-verified and flagged for a later Pro
  run.
- No `rds/{serverless,cluster,instance}/tests*/fixtures/setup` directory remains.

---

### Phase 3: Special cases — proxy and read-replica

Per decision 4b, every VPC any RDS fixture stands up moves to the reference
scheme. These two build a VPC *inside* a larger fixture (proxy: to back a real
Aurora target; read-replica: to back the real `cluster` module), so they compose
the shared fixture rather than replacing a standalone `setup` run. (See Open
Question 1 for the compose-vs-retag decision.)

#### Tasks

- [x] `rds/read-replica` `tests-localstack-pro/fixtures/cluster/main.tf`: replace
  the inline `aws_vpc` + `aws_subnet.private` + `aws_s3_bucket` + `vpc_state`
  with `module "vpc" { source = "../../../../../../test/fixtures/reference-vpc" … }`
  (six levels up — verify); set the real `cluster` module's
  `depends_on = [module.vpc]`; write the cluster stub state into
  `module.vpc.bucket_name`.
- [x] `rds/proxy` `tests-localstack-pro/fixtures/db/main.tf`: source the shared
  fixture; use `module.vpc.private_subnet_ids` for
  `aws_db_subnet_group.this.subnet_ids`; write the target stub state into
  `module.vpc.bucket_name`; drop the inline `aws_vpc` + two `aws_subnet`.
- [x] Grep-confirm no fixture under `modules/rds/` still creates a
  `Tier`-tagged subnet.

#### Success Criteria

- `just tf test-localstack-pro rds/proxy` and `rds/read-replica` green against
  LocalStack Pro (named volume) — or plan-verified and flagged for a later Pro
  run.
- `grep -rn 'Tier *=' modules/rds/**/fixtures` returns nothing.
- proxy's target-state and read-replica's cluster-state seeds are unchanged in
  shape (only the VPC underneath them moved to the shared fixture).

---

### Phase 4: Plan-time override stubs

Mirror the nine-key schema into the plan-time `override_data` blocks (decision
3a). These are values-only — plan tests do not create a VPC — so each block's
`outputs` map grows from two keys to nine with synthetic, per-tier-distinct IDs.

#### Tasks

- [x] `rds/serverless`: update the `data.terraform_remote_state.vpc`
  `override_data` blocks across the six `tests/*.tftest.hcl` files to the
  nine-key `outputs` map.
- [x] `rds/cluster`: update the five `tests/*.tftest.hcl` files **and**
  `tests-localstack/plan_smoke.tftest.hcl`.
- [x] `rds/instance`: update the six `tests/*.tftest.hcl` files **and**
  `tests-localstack/plan_smoke.tftest.hcl`.
- [x] Leave `proxy` / `read-replica` plan tests untouched — they override
  `data.terraform_remote_state.target` / `.rds_cluster`, not `.vpc`.

#### Success Criteria

- `just tf test rds/serverless`, `rds/cluster`, and `rds/instance` all green with
  the nine-key schema.
- No `.vpc` `override_data` block anywhere under `modules/rds/` seeds fewer than
  nine outputs.

---

### Phase 5: Verify and document

#### Tasks

- [ ] `just tf all rds/<m>` (validate + lint + fmt + test) for `serverless`,
  `cluster`, `instance`; `just tf validate|lint|fmt` for `proxy`,
  `read-replica`.
- [ ] Regenerate any `USAGE.md` that changed (fixtures are test-only → expect
  none; confirm).
- [ ] Update the affected `tests-localstack*/FINDINGS.md` notes to reference the
  shared fixture + the three-tier topology.
- [ ] Update `CLAUDE.md`: record the shared `test/fixtures/reference-vpc` and the
  RDS adoption.
- [ ] Flip DESIGN-0016 and IMPL-0014 status to Implemented / Completed;
  `docz update`.

#### Success Criteria

- Every RDS module's gates are green (plan for all five; Community/Pro applies
  where runnable in the session, else plan-verified + flagged).
- No `Tier`-tagged subnet remains under `modules/rds/`; `CLAUDE.md` and
  DESIGN-0016 reflect the shipped state.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `test/fixtures/reference-vpc/{versions,variables,main,outputs}.tf` | Create | The shared reference topology + nine-output state seeder |
| `test/fixtures/reference-vpc/.tflint.hcl` | Create | Lint config mirroring a sibling fixture |
| `modules/rds/serverless/tests-localstack/apply_localstack.tftest.hcl` | Modify | Repoint `run "setup"` at the shared fixture |
| `modules/rds/serverless/tests-localstack/fixtures/setup/` | Delete | Superseded by the shared fixture |
| `modules/rds/cluster/tests-localstack-pro/apply_pro.tftest.hcl` | Modify | Repoint `run "setup"` |
| `modules/rds/cluster/tests-localstack-pro/fixtures/setup/` | Delete | Superseded |
| `modules/rds/instance/tests-localstack-pro/apply_pro.tftest.hcl` | Modify | Repoint `run "setup"` |
| `modules/rds/instance/tests-localstack-pro/fixtures/setup/` | Delete | Superseded |
| `modules/rds/read-replica/tests-localstack-pro/fixtures/cluster/main.tf` | Modify | Compose the shared fixture for the VPC portion |
| `modules/rds/proxy/tests-localstack-pro/fixtures/db/main.tf` | Modify | Compose the shared fixture for the DB subnets |
| `modules/rds/{serverless,cluster,instance}/tests/*.tftest.hcl` | Modify | Nine-key `override_data` VPC stubs (17 files) |
| `modules/rds/{cluster,instance}/tests-localstack/plan_smoke.tftest.hcl` | Modify | Nine-key `override_data` VPC stubs |
| `CLAUDE.md`, `docs/design/0016-*.md` | Modify | Record shipped state; flip statuses |

## Testing Plan

- **Plan gate (`just tf test <m>`):** all five modules stay green; the nine-key
  stubs must not break existing assertions (RDS reads only two of the nine).
- **Community apply (`just tf test-localstack rds/serverless`):** the shared
  fixture applies and the serverless cluster binds `private_subnet_ids`.
- **Pro apply (`just tf test-localstack-pro rds/{cluster,instance,proxy,read-replica}`):**
  named-volume LocalStack Pro; green applies (or plan-verified + flagged if Pro
  is unavailable in the session).
- **Fidelity check:** grep confirms zero `Tier`-tagged subnets and zero
  sub-nine-key `.vpc` stubs remain under `modules/rds/`.
- No new RDS assertions are added (DESIGN-0016 Testing Strategy — see Open
  Question 5).

## Dependencies

- **Phase 1 blocks Phases 2–3** — every consumer sources the shared fixture.
- **DESIGN-0016 resolutions** (1a / 2a / 3a / 4b / 5a) are the decisions of
  record.
- **LocalStack Pro + named volume** for the `cluster` / `instance` / `proxy` /
  `read-replica` applies (macOS `initdb` ownership gotcha — see the modules'
  `FINDINGS.md`).
- **Prior art:** `modules/network/vpc-lookup/tests-localstack/fixtures/setup`
  is the topology template.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
> (Reply e.g. "1a, 2a, 3a, 4a, 5a" or override any with your own.)
>
> **Resolved 2026-07-17 — 1a, 2a, 3a, 4a, 5a (all recommendations accepted).**
> Full special-case adoption (1a), `test/fixtures/reference-vpc` at the repo root
> (2a), real IGW/NAT/route-table fidelity (3a), one PR for the whole slice (4a),
> no new assertions (5a). Each option **a** is the decision of record.

### 1. How deeply should the special-case fixtures adopt the shared fixture?

`proxy` and `read-replica` build a VPC inside a larger fixture (with their own S3
bucket + a non-VPC primary state).

- **a — Full adoption.** *(recommended)* Both source the shared fixture and use
  its `bucket_name` + `private_subnet_ids` outputs (read-replica adds
  `depends_on = [module.vpc]` for the real cluster module). Maximal DRY; every
  VPC in the fleet's fixtures is literally the same module. Costs a more careful
  refactor of the two Pro fixtures.
- **b — Retag in place.** Only the direct three adopt the shared fixture; `proxy`
  and `read-replica` keep their inline VPCs but retag subnets to the `Network`
  scheme (read-replica also expands its seeded VPC state to nine outputs). Less
  refactor risk on the trickier fixtures; reintroduces topology duplication that
  can drift.
- **other:** (enter your own)

### 2. Where should the shared reference fixture live?

- **a — `test/fixtures/reference-vpc/` at the repo root.** *(recommended)* A new
  top-level `test/` home for shared test assets; clean relative sources from
  every module.
- **b — `modules/network/vpc-lookup/tests/fixtures/reference-vpc/`.** Co-located
  with the producer it mirrors, but RDS tests then reach into another module's
  tree for a fixture.
- **c — `test-fixtures/reference-vpc/`** (hyphenated top-level, to avoid a bare
  `test/` that tooling might confuse with Go test dirs).
- **other:** (enter your own)

### 3. How much routing/gateway detail should the shared fixture create?

- **a — Real IGW + one NAT + explicit public/private route tables +
  associations.** *(recommended)* Matches `vpc-lookup`'s own fixture; all three
  network-fact outputs are backed by real resources.
- **b — Minimal.** Create only enough to make the outputs non-empty (IGW + one
  NAT; rely on the VPC's default main route table for `route_table_ids`; skip
  explicit associations). Less fixture code, slightly less realistic.
- **other:** (enter your own)

### 4. Ship as one PR, or split the shared fixture into a precursor?

- **a — One PR for the whole RDS slice (Phases 1–5).** *(recommended)* The shared
  fixture and its RDS adoption are coupled; one reviewable unit.
- **b — Split: PR-1 the shared fixture (Phase 1), PR-2 the RDS adoption.** Lets
  the EKS/EFS slices start against a merged shared fixture sooner; two smaller
  reviews.
- **other:** (enter your own)

### 5. How strongly should the apply suites assert the fixture wiring?

- **a — No new assertions.** *(recommended)* Per DESIGN-0016's Testing Strategy —
  RDS reads nothing new, so a green apply already proves the wiring. Keep the
  diff test-side and minimal.
- **b — Add one sanity assert per apply suite** that the DB subnet group resolved
  the shared fixture's `private_subnet_ids` (belt-and-suspenders against a
  mis-wired `module.source`).
- **other:** (enter your own)

## References

- DESIGN-0016 — RDS test fixtures mirror the vpc-lookup contract (the design this
  implements).
- DESIGN-0015 (addendum) / DESIGN-0017 — the EKS and EFS slices that reuse the
  shared fixture.
- INV-0004 — the VPC remote-state contract.
- `modules/network/vpc-lookup/tests-localstack/fixtures/setup/main.tf` — the
  topology template.
- `modules/rds/proxy/tests-localstack-pro/fixtures/db/main.tf`,
  `modules/rds/read-replica/tests-localstack-pro/fixtures/cluster/main.tf` — the
  special-case fixtures.
