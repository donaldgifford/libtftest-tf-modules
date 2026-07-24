---
id: DESIGN-0017
title: "EFS test fixture mirrors the vpc-lookup remote-state contract"
status: Draft
author: Donald Gifford
created: 2026-07-23
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0017: EFS test fixture mirrors the vpc-lookup remote-state contract

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
  - [The second seeded state: EKS](#the-second-seeded-state-eks)
  - [Change inventory](#change-inventory)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [1. Shared reference fixture, or per-module duplication?](#1-shared-reference-fixture-or-per-module-duplication)
  - [2. Seed the full nine-output contract, or a minimal superset?](#2-seed-the-full-nine-output-contract-or-a-minimal-superset)
  - [3. Bring the ~23 plan-time override stubs up to the same schema?](#3-bring-the-23-plan-time-override-stubs-up-to-the-same-schema)
  - [4. Normalize the second (EKS) seeded state too?](#4-normalize-the-second-eks-seeded-state-too)
  - [5. How many AZs should the reference fixture span?](#5-how-many-azs-should-the-reference-fixture-span)
- [References](#references)
<!--toc:end-->

## Overview

`modules/efs/filesystem` reads the VPC remote state for `vpc_id`
(`network.tf:24`) and `private_subnet_ids` (`mount_targets.tf:16`), but its test
fixture stubs that state at **low fidelity**: three `Tier = "private"` subnets,
no public or private-EKS tier, and a seeded state carrying only `vpc_id` +
`private_subnet_ids` — two of `vpc-lookup`'s nine outputs. This design makes the
EFS fixture a **faithful stand-in** for what `vpc-lookup` publishes: the
three-tier `Network`-tagged topology and the full output contract, computed from
the fixture's own resources.

EFS stays a pure **data-tier** consumer — the module source is untouched; it
still reads only `vpc_id` + `private_subnet_ids`. This is the EFS slice of a
fleet-wide effort; the EKS slice is DESIGN-0015 and the RDS slice DESIGN-0016.

## Goals and Non-Goals

### Goals

- The EFS `setup` fixture builds the `vpc-lookup` **reference topology**: public
  / private / private-EKS subnets across ≥ 2 AZs with the real `Network` scheme
  plus the passive `kubernetes.io/role/{elb,internal-elb}` tags.
- Its seeded VPC `terraform.tfstate` mirrors the **full** nine-output contract,
  each value computed from the fixture's own resources.
- **No change to the EFS module source** — it keeps reading only `vpc_id` +
  `private_subnet_ids`. Test-fidelity change, not behavioural.
- Keep the plan-only `tests/` and Community `tests-localstack/` suites green.

### Non-Goals

- **Instantiating `vpc-lookup`** — the fixture *maps to* its output shape without
  running it (owner decision).
- **Changing what EFS reads** — EFS is the data tier; mount targets land on
  `private_subnet_ids`, never `private_eks_subnet_ids`.
- **Reworking the second (EKS) seeded state** beyond leaving it correct — see
  Detailed Design; whether it is also normalized is an open question.
- **The create-or-adopt `modules/network/vpc`** (INV-0004) — separate work.

## Background

- **INV-0004** established the consumed contract: `vpc_id` +
  `private_subnet_ids` at `${region}/vpc/${name}/terraform.tfstate`.
- **`vpc-lookup`** (PR #51/#52) publishes nine outputs from a three-tier topology
  discriminated by a `Network` tag (`Public` / `Private` / `Private EKS`), with
  `kubernetes.io/role/{elb,internal-elb}` passive tags.
- **Survey (2026-07):** `efs/filesystem/tests-localstack/fixtures/setup/main.tf`
  creates three `Tier = "private"` subnets (AZ a/b/c) and seeds `vpc_id` +
  `private_subnet_ids` at `:106-114`. It **also** writes a second stub state — an
  EKS state exposing `node_security_group_id` at `:120` — because EFS reads that
  from the EKS remote state to authorize NFS ingress from the cluster nodes. The
  plan tests carry ~23 `override_data` blocks on `data.terraform_remote_state.vpc`
  across `default` / `validation` / `lifecycle_policy` / `sg_ingress` /
  `mount_target_count` / `backup_policy` / `managed_kms` / `byo_kms` /
  `access_points`, all with the same two-key subset.
- **Prior art:** `vpc-lookup`'s own LocalStack fixture already builds the exact
  three-tier `Network`-tagged reference VPC — the natural template or literal
  source for a shared fixture (Open Question 1).

## Detailed Design

### The reference fixture

A *`vpc-lookup`-faithful* seed fixture stands up:

```hcl
# Subnets — 3 tiers x N AZs (N >= 2)
public:      { Network = "Public",      "kubernetes.io/role/elb"          = "1" }
private:     { Network = "Private",     "kubernetes.io/role/internal-elb" = "1" }
private_eks: { Network = "Private EKS" }

# Gateways / routing so the network-fact outputs are non-empty
aws_internet_gateway + aws_eip + aws_nat_gateway (>= 1) + route tables

# Seeded terraform.tfstate outputs (full contract, computed from the above)
vpc_id, private_subnet_ids, private_eks_subnet_ids, public_subnet_ids,
vpc_cidr_block, availability_zones, nat_gateway_ids, route_table_ids,
internet_gateway_id
```

EFS mount targets still bind `private_subnet_ids`; the other eight outputs are
present so the seeded VPC state is a faithful mirror rather than a subset (Open
Question 2 covers full-vs-minimal).

### The second seeded state: EKS

EFS is unusual among the data-tier consumers: its fixture seeds **two** remote
states — the VPC contract state *and* a minimal EKS state exposing
`node_security_group_id` (so the filesystem's SG ingress rule can reference the
node SG). This design's core is the VPC state. The EKS state is orthogonal to the
`vpc-lookup` contract, so whether it is left as-is or also normalized is Open
Question 4. The recommendation is to leave the EKS state untouched — it is not a
VPC-contract state and nothing about the `vpc-lookup` topology applies to it.

### Change inventory

| # | File | Change |
|---|------|--------|
| 1 | `tests-localstack/fixtures/setup/main.tf` | replace the three `Tier="private"` subnets with the three-tier `Network` topology; add IGW / NAT / route tables (per OQ2); expand the seeded VPC state `outputs` from 2 keys to the full nine (`:106-114`) |
| 2 | `tests/*.tftest.hcl` (~23 `override_data` blocks) | *(optional, OQ3)* grow each VPC `outputs` map to the nine-key schema (values only) |
| 3 | second (EKS) seeded state (`:120`) | *(optional, OQ4)* leave as-is (recommended) |
| 4 | `USAGE.md` / `tests-localstack/FINDINGS.md` | regenerate / note the topology where relevant |

If shared-fixture (OQ1) is chosen, row 1 collapses to "repoint `run "setup"` at
`test/fixtures/reference-vpc`" — the EKS state seeding stays local to EFS.

## API / Interface Changes

- **Module inputs / outputs:** none. This design changes only `tests*/` fixtures
  (and, per OQ3, plan `override_data` values).
- **Fixture interface (if shared, OQ1):** consumes the new
  `test/fixtures/reference-vpc` module.

## Data Model

No production state-shape change. The seeded *test* VPC state's `outputs` block
grows from two keys to nine; subnet tags move from `Tier` to `Network` + the
passive `kubernetes.io/role/*` tags. The separate EKS stub state is unchanged.

## Testing Strategy

- **Plan-only `tests/` (the gate):** assertions unchanged; if OQ3 = yes, each of
  the ~23 `override_data` VPC maps gains the seven additional keys (values only).
- **Community `tests-localstack/`:** the `setup` fixture stands up the reference
  topology and seeds the full-contract VPC state; the EFS apply consumes `vpc_id`
  + `private_subnet_ids` exactly as before, and the mount-target-per-AZ behaviour
  is exercised against correctly-tagged private subnets. Green suite is the
  acceptance bar.
- **No new EFS assertions required** — EFS reads nothing new; the value is
  fixture realism. (EFS's LocalStack apply is Community-safe — pure EFS/EC2 — so
  no Pro tier or named-volume caveat applies.)

## Migration / Rollout Plan

1. Resolve the open questions (esp. shared-vs-per-module).
2. If shared: repoint EFS `run "setup"` at `test/fixtures/reference-vpc`
   (landed by whichever slice ships first). If per-module: upgrade the fixture in
   place.
3. Run the EFS plan + Community suites — purely test-side, no production or
   operator impact, no data-plane risk.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
> (Reply e.g. "1a, 2a, 3b, 4a, 5a" or override any with your own.)
>
> Questions 1–3 are the cross-cutting decisions shared with DESIGN-0015 and
> DESIGN-0016; answer them once for all three.

### 1. Shared reference fixture, or per-module duplication?

- **a — One shared `test/fixtures/reference-vpc` module** the EFS `setup` sources.
  *(recommended)* Single source of truth, no drift, nearly the fixture
  `vpc-lookup` already ships. Accepts cross-module test coupling.
- **b — Per-module fixture.** EFS grows its own three-tier + full-contract
  topology. Preserves isolation; accepts a copy that will drift from the RDS/EKS
  copies.
- **other:** (enter your own)

### 2. Seed the full nine-output contract, or a minimal superset?

- **a — Full contract.** *(recommended)* Seed all nine outputs (and create the
  IGW / NAT / route tables that back the gateway/routing outputs), so the fixture
  is a faithful mirror.
- **b — Minimal-plus.** Add the `Network` tags + private-EKS tier, seed only
  `vpc_id` / `private_subnet_ids` / `public_subnet_ids`; skip the
  gateway/routing/CIDR/AZ facts EFS never reads.
- **other:** (enter your own)

### 3. Bring the ~23 plan-time override stubs up to the same schema?

- **a — Yes, mirror the schema.** *(recommended)* Give each plan stub the nine-key
  `outputs` map (synthetic IDs) so plan and apply agree on shape. Values-only, no
  new subnets — but it touches ~23 blocks across nine files.
- **b — Apply fixture only.** Leave the plan `override_data` blocks as the two-key
  subset; only the LocalStack fixture gets the full topology. Much less churn.
- **other:** (enter your own)

### 4. Normalize the second (EKS) seeded state too?

- **a — Leave the EKS stub state as-is.** *(recommended)* It is not a VPC-contract
  state; the `vpc-lookup` topology does not apply to it. Out of scope.
- **b — Normalize it** for whatever consistency it affords (e.g. any subnet tags
  it carries).
- **other:** (enter your own)

### 5. How many AZs should the reference fixture span?

- **a — Three AZs.** *(recommended)* Matches the topology `vpc-lookup` discovers
  and the fixture's current three private subnets; exercises multi-AZ mount
  targets.
- **b — Two AZs.** The minimum; smaller/faster fixture.
- **other:** (enter your own)

## References

- INV-0004 — VPC module downstream remote-state contract.
- DESIGN-0015 — EKS slice (cluster rewire + EKS fixture fidelity).
- DESIGN-0016 — RDS slice of this effort.
- DESIGN-0008 — EFS Filesystem Module (the module whose fixture changes).
- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- PR #51 / #52 — `vpc-lookup` module + the three-tier `Network` topology.
- `modules/network/vpc-lookup/tests-localstack/fixtures/setup/main.tf` — the
  reference topology, already written.
- `efs/filesystem/tests-localstack/fixtures/setup/main.tf` — the fixture to
  upgrade.
