---
id: DESIGN-0015
title: "Rewire EKS cluster to the private EKS subnet tier"
status: Draft
author: Donald Gifford
created: 2026-07-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0015: Rewire EKS cluster to the private EKS subnet tier

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-07-15

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [The production change (one line)](#the-production-change-one-line)
  - [What does NOT change](#what-does-not-change)
  - [Optional precondition guard](#optional-precondition-guard)
  - [Change inventory](#change-inventory)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [1. Guard the EKS subnet count with a precondition?](#1-guard-the-eks-subnet-count-with-a-precondition)
  - [2. How to handle a VPC state missing the EKS subnet output?](#2-how-to-handle-a-vpc-state-missing-the-eks-subnet-output)
  - [3. How strongly should the tests prove the tier binding?](#3-how-strongly-should-the-tests-prove-the-tier-binding)
  - [4. Retag the cluster's LocalStack fixture to the Network scheme?](#4-retag-the-clusters-localstack-fixture-to-the-network-scheme)
  - [5. Update DESIGN-0002, or leave it historical?](#5-update-design-0002-or-leave-it-historical)
  - [6. Emit a cluster subnet-IDs observability output?](#6-emit-a-cluster-subnet-ids-observability-output)
- [References](#references)
<!--toc:end-->

## Overview

`modules/network/vpc-lookup` now publishes a **three-tier** subnet topology:
`private_subnet_ids` (data tier — RDS/EFS + EKS worker nodes),
`public_subnet_ids`, and the new `private_eks_subnet_ids` — the *internal EKS
cluster IP range* dedicated to the control-plane ENIs. This design rewires
`modules/eks/cluster` so its `aws_eks_cluster.vpc_config.subnet_ids` reads
`private_eks_subnet_ids` instead of `private_subnet_ids`. Worker nodes
(`modules/eks/managed-node-group`) stay on the data-tier `private_subnet_ids`.

The production change is a **single line**; the bulk of the work is updating the
VPC-state stubs across the cluster's test suites (native HCL + libtftest Go).

## Goals and Non-Goals

### Goals

- Point the EKS control-plane ENIs (`aws_eks_cluster.vpc_config.subnet_ids`) at
  the dedicated `private_eks_subnet_ids` tier from VPC remote state.
- Keep the change internal — **no change to the cluster's output contract**, so
  no downstream consumer (addons, pod-identity-access, managed-node-group) is
  affected.
- Update every VPC-state stub (4 HCL `override_data` blocks, the libtftest Go
  seed, and the LocalStack fixture) to carry the new output, and prove the
  cluster binds to the *EKS* tier (not the data tier).
- Preserve green plan-only, LocalStack-apply, and libtftest suites.

### Non-Goals

- **Worker-node placement.** `managed-node-group` keeps reading
  `private_subnet_ids`; nodes stay in the data tier (owner decision). Out of
  scope here.
- **The full create-or-adopt `modules/network/vpc`** (INV-0004) — separate work.
- **Kubernetes-layer pod networking** (VPC CNI custom networking / `ENIConfig`).
  Whether pods draw IPs from the private-EKS range is a K8s-API concern delivered
  out-of-band (ADR-0011 / the no-K8s-in-Terraform rule), not this module.
- **Fixing the pre-existing DESIGN-0002 drift** where the doc says
  `endpoint_public_access = false` but the code defaults it `true`
  (`variables.tf:69-73`). Noted, unrelated, left alone.
- **Retiring the fleet's stub-`Tier`-tag fixtures** wholesale (only the
  cluster's fixture is in scope; see Open Question 4).

## Background

- **INV-0004** established that the VPC remote-state contract every data/compute
  module consumes was exactly `vpc_id` + `private_subnet_ids`, published at
  `${region}/vpc/${name}/terraform.tfstate`.
- **`vpc-lookup`** (PR #51) shipped as the read-only producer; **PR #52** added
  the third tier: subnets are discriminated by a `Network` tag
  (`Public` / `Private` / `Private EKS`), with `kubernetes.io/role/{elb,internal-elb}`
  as passive LB-controller-discovery tags. It now emits `private_eks_subnet_ids`.
- **CLAUDE.md:130-131** already records this task as the pending follow-up:
  *"`private_subnet_ids` stays the data tier (RDS/EFS + EKS worker nodes); a
  follow-up rewires `eks/cluster` to `private_eks_subnet_ids`."*
- **DESIGN-0002** (EKS Cluster Module, Accepted 2026-05-13) predates the split —
  it documents a single private tier feeding both the cluster and the nodes.
- **Today** the cluster reads the VPC state in exactly two places
  (`data.tf:18-27`): `main.tf:50` (subnets → `vpc_config`) and
  `security_group.tf:14` (`vpc_id` → node SG). Only the first moves.

## Detailed Design

### The production change (one line)

`modules/eks/cluster/main.tf:50`, inside `aws_eks_cluster.this.vpc_config`:

```hcl
# before
subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
# after
subnet_ids = data.terraform_remote_state.vpc.outputs.private_eks_subnet_ids
```

The state key, backend config, and the `data.terraform_remote_state.vpc` block
itself (`data.tf:18-27`) are unchanged — the module already reads the state file
that carries the new output.

### What does NOT change

- `security_group.tf:14` — the node SG's `vpc_id` read is untouched.
- `outputs.tf` — the cluster emits **no** subnet/AZ output (8 outputs, all
  identity/endpoint/SG/KMS). The rewire is a terminal sink → **zero output
  contract change**, so addons / pod-identity-access / managed-node-group (which
  read the cluster's `eks` remote state) are unaffected.
- `modules/eks/managed-node-group/main.tf:17` — nodes keep
  `private_subnet_ids`. No change.
- `modules/eks/addons`, `modules/eks/pod-identity-access` — never read VPC
  subnets. No change.

### Optional precondition guard

EKS requires ≥ 2 subnets in ≥ 2 AZs for a cluster. Today nothing guards this — a
mis-tagged or single-AZ `private_eks` tier surfaces as a cryptic AWS API error at
apply. A resource `precondition` on `aws_eks_cluster.this` (the established
`>= 1.1` idiom — cf. `managed-node-group/main.tf:70-76`) turns it into a clear
plan-time failure:

```hcl
lifecycle {
  precondition {
    condition     = length(data.terraform_remote_state.vpc.outputs.private_eks_subnet_ids) >= 2
    error_message = "VPC private_eks_subnet_ids must contain >= 2 subnets in >= 2 AZs (EKS control-plane requirement)."
  }
}
```

See **Open Question 1**.

### Change inventory

| # | File | Change |
|---|------|--------|
| 1 | `modules/eks/cluster/main.tf:50` | `private_subnet_ids` → `private_eks_subnet_ids` (the rewire) |
| 2 | `modules/eks/cluster/main.tf` (`aws_eks_cluster.this`) | *(optional, OQ1)* add `lifecycle.precondition` on ≥ 2 EKS subnets |
| 3 | `tests/default.tftest.hcl:46-55` | add `private_eks_subnet_ids` to the `override_data` outputs; update the subnet assertion at `:137-140` to bind against the EKS tier |
| 4 | `tests/kms_external.tftest.hcl:42-51` | add `private_eks_subnet_ids` to `override_data` |
| 5 | `tests/sso.tftest.hcl:43-52` and `:81-90` | add `private_eks_subnet_ids` to **both** `override_data` blocks |
| 6 | `test/helpers_test.go:132-136` (`seedVPCState`) | add a `private_eks_subnet_ids` entry (+ a `stubPrivateEKSSubnets` var near `:27-30`); *(optional)* a Go assertion that `vpc_config.subnet_ids` == the EKS stub |
| 7 | `tests-localstack/fixtures/setup/main.tf` | add `aws_subnet.private_eks` (distinct CIDR), a `private_eks_subnet_ids` key in the `jsonencode` state body (`:96-103`), and a module output |
| 8 | `USAGE.md` / `tests-localstack/FINDINGS.md` | regenerate / note the third tier where relevant |

To *prove* the rewire (not just keep tests green), the stubs should give
`private_eks_subnet_ids` **distinct** IDs from `private_subnet_ids`, and at least
one assertion should confirm the cluster's `vpc_config.subnet_ids` resolves to the
EKS set (see Open Question 3).

## API / Interface Changes

- **Module inputs:** none. (`remote_state_bucket`, `region`, `vpc_name` unchanged.)
- **Module outputs:** none — the 8-output contract is byte-identical.
- **Upstream requirement (new):** the VPC remote state the cluster reads MUST now
  expose `private_eks_subnet_ids`. `vpc-lookup` (≥ PR #52) always does; hand-rolled
  VPC states predating the split would not (see Migration + Open Question 2).

## Data Model

No schema/state-shape changes in the cluster's own state. The only data-model
touchpoint is the *consumed* VPC state contract, which gains one list output
(`private_eks_subnet_ids`, `list(string)`) already produced upstream.

## Testing Strategy

- **Plan-only `tests/` (the gate):** each `override_data` stub gains
  `private_eks_subnet_ids` (distinct IDs). Update `default.tftest.hcl:137-140` and
  add an assertion that `aws_eks_cluster.this.vpc_config[0].subnet_ids` equals the
  stubbed EKS set — the regression lock for "cluster binds the EKS tier, not the
  data tier."
- **libtftest Go (`test/`):** extend `seedVPCState` (`helpers_test.go`) with the
  EKS stub; optionally assert the bound subnets in `cluster_test.go`.
- **LocalStack apply (`tests-localstack/`):** the `fixtures/setup` stands up a
  distinct `private_eks` subnet pair and writes it into the stub state; the real
  `aws_eks_cluster` apply consumes it. (EKS on LocalStack is Community-gated per
  the module's existing `FINDINGS.md` — the active mode is unchanged by this work.)
- **Fleet regression:** `managed-node-group`, `addons`, `pod-identity-access`
  suites must stay green untouched (they don't read the EKS tier).

## Migration / Rollout Plan

1. Land `vpc-lookup` with `private_eks_subnet_ids` — **done** (PR #52, `main`).
2. Land this rewire (cluster reads the EKS tier) + test updates.
3. Operators applying a live cluster must have a VPC state that already exposes
   `private_eks_subnet_ids`. With `vpc-lookup` that is automatic. The concern is a
   hand-rolled/legacy VPC state without the output — see **Open Question 2** for
   hard-cut vs. `try()` fallback.
4. No data-plane disruption for **existing** clusters unless the EKS tier differs
   from the current private tier: if an already-running cluster's
   `vpc_config.subnet_ids` changes, EKS treats control-plane subnet changes as an
   in-place update (it does not force cluster replacement), but it is still a live
   change — call it out in the operator's plan review. Greenfield clusters are
   unaffected.

## Open Questions

> Format: each question is numbered; options are lettered. **a = my
> recommendation**; b+ are alternatives; **other** = your free-text call.
> (Reply e.g. "1a, 2b, 3a, 4a, 5a, 6a" or override any with your own.)
>
> **Resolved 2026-07-17 — 1a, 2a, 3a, 4a, 5a, 6a (all recommendations
> accepted).** Each option **a** below is the decision of record.

### 1. Guard the EKS subnet count with a precondition?

EKS requires ≥ 2 subnets across ≥ 2 AZs.

- **a — Add a `lifecycle.precondition` on `aws_eks_cluster.this` asserting
  `length(private_eks_subnet_ids) >= 2`.** *(recommended)* Clear plan-time error
  instead of a cryptic AWS API failure; matches the `>= 1.1` precondition idiom
  already used in `managed-node-group`.
- **b — No guard.** Rely on the AWS API to reject a bad subnet set at apply.
- **c — Guard non-empty only (`>= 1`).** Cheaper, but doesn't catch the
  single-AZ case EKS also rejects.
- **other:** (enter your own)

### 2. How to handle a VPC state missing the EKS subnet output?

- **a — Hard cut: read `private_eks_subnet_ids` directly.** *(recommended)*
  `vpc-lookup` always emits it and the 3-tier topology is the fleet convention;
  there are no in-repo legacy states. A missing output should fail loudly.
- **b — Graceful fallback:
  `try(...private_eks_subnet_ids, ...private_subnet_ids)`.** Eases transition for
  operators with hand-rolled VPC states, at the cost of silently masking a
  mis-provisioned VPC (the cluster would land in the data tier). Remove after
  migration.
- **other:** (enter your own)

### 3. How strongly should the tests prove the tier binding?

- **a — Distinct stub IDs + an explicit assertion** that
  `vpc_config[0].subnet_ids` equals the stubbed `private_eks_subnet_ids` (HCL
  plan assert + a libtftest Go assert). *(recommended)* Locks the rewire against
  regression.
- **b — Distinct stub IDs, HCL assertion only** (skip the new Go assert; just
  extend the Go seed map).
- **c — Minimal: add the stub output, keep the existing count-only assertion.**
  Least churn, weakest guarantee.
- **other:** (enter your own)

### 4. Retag the cluster's LocalStack fixture to the `Network` scheme?

The fixture writes the stub state **directly** (`jsonencode`), so subnet tags
don't affect discovery — only the JSON output key matters.

- **a — Add the `private_eks` subnets and retag all tiers to the real
  `Network = "Public"/"Private"/"Private EKS"` scheme** for realism/consistency
  with `vpc-lookup`, even though the fixture bypasses tag-based discovery.
  *(recommended)*
- **b — Minimal churn: add the `private_eks` subnets + the JSON output key, keep
  the existing `Tier` tags.**
- **other:** (enter your own)

### 5. Update DESIGN-0002, or leave it historical?

DESIGN-0002 documents the old single-private-tier wiring.

- **a — Leave DESIGN-0002 as the accepted historical record; add a one-line
  "amended by DESIGN-0015" pointer to its subnet section.** *(recommended)*
- **b — Edit DESIGN-0002's subnet section in place** to describe the 3-tier split.
- **other:** (enter your own)

### 6. Emit a cluster subnet-IDs observability output?

- **a — No.** *(recommended)* Consumers read the VPC state directly; keep the
  cluster's output contract minimal and unchanged.
- **b — Yes**, add `cluster_subnet_ids` (the EKS subnets the control plane uses)
  for operator visibility.
- **other:** (enter your own)

## References

- INV-0004 — VPC module downstream remote-state contract (the 3-tier split).
- DESIGN-0002 — EKS Cluster Module (the module being amended).
- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- ADR-0011 — Kubernetes-API objects delivered out-of-band (pod networking scope).
- PR #51 / #52 — `vpc-lookup` module + the `private_eks_subnet_ids` tier.
- `modules/eks/cluster/main.tf:50`, `data.tf:18-27`, `security_group.tf:14`.
