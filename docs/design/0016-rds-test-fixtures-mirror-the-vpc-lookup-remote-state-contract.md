---
id: DESIGN-0016
title: "RDS test fixtures mirror the vpc-lookup remote-state contract"
status: Draft
author: Donald Gifford
created: 2026-07-23
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0016: RDS test fixtures mirror the vpc-lookup remote-state contract

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-07-23

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [The reference fixture](#the-reference-fixture)
  - [Shared fixture vs per-module duplication](#shared-fixture-vs-per-module-duplication)
  - [Per-module change inventory](#per-module-change-inventory)
  - [The two special cases: proxy and read-replica](#the-two-special-cases-proxy-and-read-replica)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [1. Shared reference fixture, or per-module duplication?](#1-shared-reference-fixture-or-per-module-duplication)
  - [2. Seed the full nine-output contract, or a minimal superset?](#2-seed-the-full-nine-output-contract-or-a-minimal-superset)
  - [3. Bring the plan-time override stubs up to the same schema?](#3-bring-the-plan-time-override-stubs-up-to-the-same-schema)
  - [4. Are proxy and read-replica in scope?](#4-are-proxy-and-read-replica-in-scope)
  - [5. How many AZs should the reference fixture span?](#5-how-many-azs-should-the-reference-fixture-span)
- [References](#references)
<!--toc:end-->

## Overview

Every RDS module that reads the VPC remote state stubs it in tests with a
**low-fidelity** VPC: subnets tagged `Tier = "private"` (not the fleet's
`Network` scheme), no public or private-EKS tier, and a seeded state that
carries only two of `vpc-lookup`'s nine outputs (`vpc_id` +
`private_subnet_ids`). This design makes those fixtures **faithful stand-ins**
for what `modules/network/vpc-lookup` actually publishes: the three-tier
`Network`-tagged topology and the full output contract, computed from the
fixture's own resources.

RDS stays a pure **data-tier** consumer — the module source is untouched; it
still reads only `vpc_id` + `private_subnet_ids`. Only the test fixtures (and,
per an open question, the plan-time `override_data` stubs) change. This is the
RDS slice of a fleet-wide effort; the EKS slice lives in DESIGN-0015 and the EFS
slice in DESIGN-0017.

## Goals and Non-Goals

### Goals

- Every RDS fixture that stands up a VPC builds the `vpc-lookup` **reference
  topology**: public / private / private-EKS subnets across ≥ 2 AZs, tagged with
  the real `Network` scheme plus the passive `kubernetes.io/role/{elb,internal-elb}`
  tags.
- The seeded `terraform.tfstate` `outputs` block mirrors the **full** nine-output
  `vpc-lookup` contract, each value computed from the fixture's own resources
  (not by running `vpc-lookup`).
- **No change to any RDS module's source** — the modules keep reading only
  `vpc_id` + `private_subnet_ids`. This is a test-fidelity change, not a
  behavioural one.
- Keep the plan-only `tests/`, Community `tests-localstack/`, and Pro
  `tests-localstack-pro/` suites green across all five RDS modules.

### Non-Goals

- **Instantiating `vpc-lookup`.** The fixtures *map to* its output shape; they do
  not run the module (owner decision — the fixture hand-computes the outputs from
  the raw resources it creates).
- **Changing what RDS reads.** RDS is the data tier; it binds `private_subnet_ids`
  and will not consume `private_eks_subnet_ids`.
- **The create-or-adopt `modules/network/vpc`** (INV-0004) — separate work.
- **Retiring hand-written stub state in favour of remote-state dogfooding**
  wholesale — the fixtures still seed a `terraform.tfstate` object; they just seed
  a faithful one.

## Background

- **INV-0004** established the consumed contract as `vpc_id` +
  `private_subnet_ids` at `${region}/vpc/${name}/terraform.tfstate`.
- **`vpc-lookup`** (PR #51/#52) is the read-only producer. It publishes nine
  outputs — `vpc_id`, `private_subnet_ids`, `private_eks_subnet_ids`,
  `public_subnet_ids`, `vpc_cidr_block`, `availability_zones`, `nat_gateway_ids`,
  `route_table_ids`, `internet_gateway_id` — discovered from a three-tier
  topology discriminated by a `Network` tag (`Public` / `Private` / `Private
  EKS`), with `kubernetes.io/role/{elb,internal-elb}` as passive
  LB-controller-discovery tags.
- **Survey (2026-07):** the RDS fixtures are uniformly low-fidelity —
  `rds/serverless/tests-localstack/fixtures/setup/main.tf:48` and
  `rds/{cluster,instance}/tests-localstack-pro/fixtures/setup/main.tf:48` each
  create three `Tier = "private"` subnets and seed only `vpc_id` +
  `private_subnet_ids`. The plan stubs (`rds/*/tests/*.tftest.hcl`) override
  `data.terraform_remote_state.vpc` with the same two-key subset.
- **Prior art for the target topology already exists:**
  `modules/network/vpc-lookup/tests-localstack/fixtures/setup/main.tf` builds the
  exact three-tier, `Network`-tagged reference VPC (with IGW + NAT). It is the
  natural template — or the literal source — for a shared fixture.

## Detailed Design

### The reference fixture

A *`vpc-lookup`-faithful* seed fixture stands up this topology and writes a stub
state whose outputs match the producer's contract byte-for-byte in shape:

```hcl
# Subnets — 3 tiers x N AZs (N >= 2)
public:      { Network = "Public",      "kubernetes.io/role/elb"          = "1" }
private:     { Network = "Private",     "kubernetes.io/role/internal-elb" = "1" }
private_eks: { Network = "Private EKS" }

# Gateways / routing (so the network-fact outputs are non-empty)
aws_internet_gateway + aws_eip + aws_nat_gateway (>= 1) + route tables

# Seeded terraform.tfstate outputs (the full contract, computed from the above)
vpc_id, private_subnet_ids, private_eks_subnet_ids, public_subnet_ids,
vpc_cidr_block, availability_zones, nat_gateway_ids, route_table_ids,
internet_gateway_id
```

The RDS module under test still reads only `vpc_id` + `private_subnet_ids`; the
other seven outputs are present so the seeded state is a faithful mirror rather
than a subset — see Open Question 2 for full-vs-minimal.

### Shared fixture vs per-module duplication

The reference topology is identical for every consumer, so the central decision
(Open Question 1) is whether to define it **once** and share it, or copy it into
each module's fixture:

- **Shared** — promote the topology to a repo-level test fixture (e.g.
  `test/fixtures/reference-vpc/`) that also seeds the stub state, parameterized by
  `remote_state_bucket` / `vpc_name` / `region`. Every consumer's
  `run "setup"` block sources it. One source of truth; no drift; already 90%
  written in `vpc-lookup`'s fixture. Cost: cross-module test coupling — a change
  to the shared fixture touches every consumer's suite.
- **Per-module** — each RDS fixture grows its own three-tier topology + full-
  contract seed. Matches the current per-module isolation and the repo's
  "self-contained module" ethos; cost is 5+ copies that will drift.

This decision is shared across DESIGN-0015 / 0016 / 0017 — resolving it here
resolves it for all three.

### Per-module change inventory

Direct `data.terraform_remote_state.vpc` consumers:

| Module | Fixture(s) to upgrade | Today | Target |
|--------|----------------------|-------|--------|
| `rds/serverless` | `tests-localstack/fixtures/setup/main.tf` | 3 × `Tier="private"`, seed 2 outputs | reference fixture |
| `rds/cluster` | `tests-localstack-pro/fixtures/setup/main.tf` | 3 × `Tier="private"`, seed 2 outputs | reference fixture |
| `rds/instance` | `tests-localstack-pro/fixtures/setup/main.tf` | 3 × `Tier="private"`, seed 2 outputs | reference fixture |

Plan-time stubs (`tests/*.tftest.hcl` + `tests-localstack/plan_smoke.tftest.hcl`)
override `data.terraform_remote_state.vpc` with a two-key `outputs` map. Whether
those grow to the full schema is Open Question 3 (they cannot *create* a VPC —
only the `outputs` values change).

### The two special cases: proxy and read-replica

Neither reads `data.terraform_remote_state.vpc`, so their inclusion is Open
Question 4:

- **`rds/proxy`** reads `data.terraform_remote_state.target` (an RDS-target
  state, not the VPC contract). Its Pro fixture
  (`tests-localstack-pro/fixtures/db/main.tf`) *does* stand up a VPC, but tags it
  `Name`-only and seeds a target state. Bringing it to the reference topology is
  cosmetic (proxy never reads the VPC tier), but it keeps every VPC the fleet's
  fixtures create on one scheme.
- **`rds/read-replica`** reads `data.terraform_remote_state.rds_cluster`. Its Pro
  fixture (`tests-localstack-pro/fixtures/cluster/main.tf`) instantiates the
  **real `rds/cluster` module**, which transitively reads the VPC state — so the
  fixture hand-writes a `Tier="private"` VPC stub to satisfy that read. That stub
  *is* a VPC-contract state and is the strongest candidate of the two for the
  upgrade.

## API / Interface Changes

- **Module inputs / outputs:** none, for any RDS module. This design changes only
  `tests*/` fixtures (and, per OQ3, plan `override_data` values).
- **Fixture interface (if shared, OQ1):** a new `test/fixtures/reference-vpc`
  module with inputs `remote_state_bucket`, `vpc_name`, `region` and outputs
  mirroring the nine-output contract.

## Data Model

No production state-shape change. The seeded *test* state's `outputs` block grows
from two keys to nine (the full `vpc-lookup` contract). Subnet tags move from
`Tier` to `Network` + the passive `kubernetes.io/role/*` tags.

## Testing Strategy

- **Plan-only `tests/` (the gate):** unchanged assertions; if OQ3 = yes, the
  `override_data` `outputs` maps gain the seven additional keys (values only).
- **Community `tests-localstack/` + Pro `tests-localstack-pro/`:** the `setup`
  fixture stands up the reference topology and seeds the full-contract state; the
  RDS apply consumes `vpc_id` + `private_subnet_ids` exactly as before. Green
  suites are the acceptance bar — the RDS resources see the same two values, just
  sourced from a richer, correctly-tagged VPC.
- **No new RDS assertions** are required (RDS reads nothing new); the value is
  fixture realism, not additional coverage. An optional sanity assert that the
  seeded private subnets resolve is possible but low-value.
- **macOS Pro caveat** unchanged: the `cluster`/`instance` Pro applies still need
  the LocalStack named-volume workaround (see each module's `FINDINGS.md`).

## Migration / Rollout Plan

1. Resolve the open questions (esp. shared-vs-per-module and proxy/read-replica
   scope).
2. If shared: land `test/fixtures/reference-vpc` first; then repoint each RDS
   `setup` fixture at it. If per-module: upgrade each fixture in place.
3. Run every RDS suite (plan + Community + Pro) — this is purely test-side, so
   there is no production or operator impact and no data-plane risk.
4. Sequence relative to DESIGN-0015 / 0017 is free; the shared fixture (if
   chosen) is the only ordering constraint.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
> (Reply e.g. "1a, 2a, 3b, 4a, 5a" or override any with your own.)
>
> Questions 1–3 are the cross-cutting decisions shared with DESIGN-0015 and
> DESIGN-0017; answering them here settles them fleet-wide.

### 1. Shared reference fixture, or per-module duplication?

- **a — One shared `test/fixtures/reference-vpc` module** every consumer sources.
  *(recommended)* Single source of truth, no drift, and it is nearly the fixture
  `vpc-lookup` already ships. Accepts cross-module test coupling.
- **b — Per-module fixtures.** Each RDS module grows its own three-tier + full-
  contract fixture. Preserves isolation; accepts 5+ copies that will drift.
- **other:** (enter your own)

### 2. Seed the full nine-output contract, or a minimal superset?

- **a — Full contract.** *(recommended)* Seed all nine outputs (and create the
  IGW / NAT / route tables that back `nat_gateway_ids` / `route_table_ids` /
  `internet_gateway_id`), so the fixture is a faithful mirror and future
  consumers of any output already have it.
- **b — Minimal-plus.** Add the `Network` tags + the private-EKS tier, but seed
  only the outputs a data-tier consumer could read (`vpc_id`,
  `private_subnet_ids`, `public_subnet_ids`) — skip the gateway/routing/CIDR/AZ
  facts RDS never uses. Less fixture code, less realism.
- **other:** (enter your own)

### 3. Bring the plan-time override stubs up to the same schema?

- **a — Yes, mirror the schema.** *(recommended)* Give the plan stubs the same
  nine-key `outputs` map (with synthetic IDs) so plan and apply agree on shape.
  Low cost, no new subnets (override is values-only).
- **b — Apply fixtures only.** Leave plan `override_data` as the two-key subset;
  only the LocalStack fixtures get the full topology. Least churn.
- **other:** (enter your own)

### 4. Are proxy and read-replica in scope?

- **a — Include `read-replica` only.** *(recommended)* Its fixture hand-writes a
  genuine VPC-contract state (via the real `cluster` module's read), so it belongs
  on the reference scheme. Leave `proxy` out — it seeds a target state, not a VPC
  contract, so retagging its VPC is cosmetic.
- **b — Include both** `proxy` and `read-replica`, so every VPC any RDS fixture
  creates uses one scheme.
- **c — Neither.** Restrict this design to the three direct `.vpc` consumers
  (`serverless`, `cluster`, `instance`).
- **other:** (enter your own)

### 5. How many AZs should the reference fixture span?

- **a — Three AZs.** *(recommended)* Matches the real topology `vpc-lookup`
  discovers and the RDS Pro fixtures' current three private subnets; exercises
  the multi-AZ subnet-group path.
- **b — Two AZs.** The minimum RDS/EKS require; smaller/faster fixture.
- **other:** (enter your own)

## References

- INV-0004 — VPC module downstream remote-state contract.
- DESIGN-0015 — EKS slice (cluster rewire + EKS fixture fidelity).
- DESIGN-0017 — EFS slice of this effort.
- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- PR #51 / #52 — `vpc-lookup` module + the three-tier `Network` topology.
- `modules/network/vpc-lookup/tests-localstack/fixtures/setup/main.tf` — the
  reference topology, already written.
- `rds/serverless/tests-localstack/fixtures/setup/main.tf`,
  `rds/{cluster,instance}/tests-localstack-pro/fixtures/setup/main.tf` — the
  fixtures to upgrade.
