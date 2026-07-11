---
id: DESIGN-0014
title: "RDS Aurora read-replica module"
status: Implemented
author: Donald Gifford
created: 2026-07-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0014: RDS Aurora read-replica module

**Status:** Implemented
**Author:** Donald Gifford
**Date:** 2026-07-09

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Position in the RDS module family](#position-in-the-rds-module-family)
  - [Composition via remote state](#composition-via-remote-state)
  - [The replicas map](#the-replicas-map)
  - [Module file layout](#module-file-layout)
  - [Resources](#resources)
  - [Validation surface](#validation-surface)
  - [Why a separate module](#why-a-separate-module)
- [API / Interface Changes](#api--interface-changes)
  - [Input surface](#input-surface)
  - [Output surface](#output-surface)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Q1 — Cluster-only, or parameterise the target (cluster vs serverless)? — RESOLVED (a)](#q1--cluster-only-or-parameterise-the-target-cluster-vs-serverless--resolved-a)
  - [Q2 — Per-reader promotion tier (failover priority) — RESOLVED (a)](#q2--per-reader-promotion-tier-failover-priority--resolved-a)
  - [Q3 — Per-reader parameter group override — RESOLVED (a)](#q3--per-reader-parameter-group-override--resolved-a)
  - [Q4 — replicas object shape — RESOLVED (a + b hybrid)](#q4--replicas-object-shape--resolved-a--b-hybrid)
  - [Q5 — Source engine version from the cluster, or leave it to Aurora? — RESOLVED (a)](#q5--source-engine-version-from-the-cluster-or-leave-it-to-aurora--resolved-a)
  - [Q6 — Aurora replica auto-scaling — RESOLVED (a)](#q6--aurora-replica-auto-scaling--resolved-a)
  - [Q7 — Guard against stale / wrong cluster remote state — RESOLVED (a)](#q7--guard-against-stale--wrong-cluster-remote-state--resolved-a)
- [References](#references)
<!--toc:end-->

## Overview

`modules/rds/read-replica` adds one or more **Aurora reader instances**
(`aws_rds_cluster_instance`) to an **existing** cluster provisioned by
`modules/rds/cluster` ([DESIGN-0013](0013-rds-aurora-provisioned-cluster-module.md)).
It owns no cluster, no subnet group, no security group, and no KMS key —
those all belong to the cluster it attaches to, which it reads via
`data.terraform_remote_state` against the cluster's S3 state key
([ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)).

This is the read-scale-out primitive: each invocation is one small Terraform
plan that stands up a pool of readers keyed by a stable map, so adding or
removing a reader is a single targeted apply that never touches the cluster's
own state. Structurally it is the closest sibling to the shipped `proxy`
module — both are *pure consumers* of another RDS module's remote state.

## Goals and Non-Goals

### Goals

- **Attach reader instances to an existing Aurora cluster** via the cluster
  module's remote-state outputs — no cluster inputs re-threaded, no drift
  possible on engine / subnet group / SG / KMS (all read from one source of
  truth).
- **`for_each` over a typed `replicas` map** (DESIGN-0007 Q1) — a stable
  identifier key per reader, so removing reader #1 of N never renumbers the
  rest.
- **Small blast radius.** One plan, one state file, one apply per read-scale
  event — independent of the cluster's lifecycle.
- **Match the proxy module's composition conventions** — `use_path_style`
  S3 backend, aliased locals reading remote-state outputs, plan-time
  preconditions guarding required-but-remote values.
- **Reader diversity.** Different `instance_class`, AZ pinning, and failover
  priority per reader in the pool (see Q2/Q4).

### Non-Goals

- **Provisioning or mutating the cluster.** The cluster is read-only input.
  Changing the writer, parameter groups, or cluster-level settings is the
  `cluster` module's job.
- **Non-Aurora (single-instance) read replicas.** Those are
  `replicate_source_db` on `aws_db_instance` — a different resource and a
  different (deferred) `instance-replica` module (DESIGN-0012 Q5).
- **Cross-region replicas.** Same-region only for v1 (DESIGN-0007 non-goal);
  cross-region needs `aws_rds_global_cluster` and a different remote-state
  shape.
- **The cluster's reader endpoint.** The cluster already emits
  `reader_endpoint` (the AWS-managed load-balanced reader DNS). This module
  emits per-reader endpoints for targeted routing, not a new pooled endpoint
  (custom endpoints are DESIGN-0013 Q7).
- **Autoscaling policies** (`aws_appautoscaling_*` for Aurora replica
  auto-scaling). Deferred (Q6) — the map is explicit for v1.

## Background

DESIGN-0007 resolved (Q1) that read replicas are a **separate module** using
`for_each` over a named map, not an `instance_count` knob on the cluster
module — for blast-radius, consumer-ergonomics, and reader-diversity reasons
restated below. The cluster module (DESIGN-0013) is being designed in the
same batch and pins the exact output names this module consumes; per the
rollout order, **read-replica must merge after cluster**.

The mechanics are already proven twice in the fleet: `proxy` (IMPL-0010)
reads a target DB's remote state with the identical `use_path_style` S3
backend and aliased-locals pattern, and its Pro test suite bridges remote
state through a real S3-object fixture — the same technique this module's
apply suite needs (because `override_data` can't reference a prior apply's
outputs).

Provider baseline unchanged: `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.

## Detailed Design

### Position in the RDS module family

```text
modules/rds/
├── instance/      — single aws_db_instance (DESIGN-0012)
├── cluster/       — Aurora provisioned; SOURCE-OF-TRUTH state (DESIGN-0013)
├── read-replica/  ← THIS MODULE — readers attached via cluster's remote state
└── serverless/    — Aurora Serverless v2 (shipped, IMPL-0007)
```

### Composition via remote state

Exactly the proxy pattern. A single data source, `use_path_style = true` for
LocalStack, reading the cluster's state at the fleet-standard key:

```hcl
# main.tf
data "terraform_remote_state" "rds_cluster" {
  backend = "s3"
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/rds/cluster/${var.cluster_identifier}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
```

Outputs consumed from the cluster (aliased into `locals.tf`, "read at the use
site" — the same convention proxy uses):

```hcl
# locals.tf
cluster_identifier      = data.terraform_remote_state.rds_cluster.outputs.cluster_identifier
engine                  = data.terraform_remote_state.rds_cluster.outputs.engine
engine_version_actual   = data.terraform_remote_state.rds_cluster.outputs.engine_version_actual
db_subnet_group_name    = data.terraform_remote_state.rds_cluster.outputs.db_subnet_group_name
db_parameter_group_name = data.terraform_remote_state.rds_cluster.outputs.db_parameter_group_name
# (security_group_id + kms_key_arn are cluster-owned; readers inherit them
#  from the cluster automatically and need not be re-set — see Q3/Q5.)
```

The cluster module (DESIGN-0013) is designed to emit every one of these. Q1
resolved to **cluster-only for v1**, so the `rds/cluster/` key segment is
hardcoded (no `target_type` input); a future DESIGN can generalise to
serverless targets via a `target_dir_map` like the proxy's.

### The replicas map

Per DESIGN-0007 Q1, `for_each` over a typed object map. Q4 resolved to a
**hybrid**: a minimal required core (only `instance_class`), with the richer
per-reader settings exposed as **optional** attributes that default to the
common case — so a caller passes just `instance_class`, or opts into the
advanced knobs per reader:

```hcl
variable "replicas" {
  type = map(object({
    instance_class    = string
    availability_zone = optional(string)       # null → Aurora auto-distributes
    promotion_tier    = optional(number, 15)   # failover priority (Q2)

    # Optional advanced per-reader settings (Q4 hybrid) — default to the
    # common case; opt in per reader when needed.
    performance_insights_enabled = optional(bool, false)
    monitoring_interval          = optional(number, 0) # enhanced monitoring
    monitoring_role_arn          = optional(string)    # required if interval > 0
    auto_minor_version_upgrade   = optional(bool, true)
    publicly_accessible          = optional(bool, false)
  }))
  nullable = false
}
```

- **Key** = a stable identifier suffix; the reader is named
  `${var.identifier_prefix}-replica-${each.key}`. A single reader is a
  one-entry map; the empty map `{}` legitimately means zero readers.
- `engine` / `engine_version` come from the cluster's remote state, not the
  map — a reader can never drift from its cluster's engine by construction.

### Module file layout

Small — no KMS / subnet-group / SG files (all cluster-owned):

```text
modules/rds/read-replica/
├── versions.tf   — required_version >= 1.1, aws ~> 6.2
├── variables.tf  — pointers (region, bucket, cluster_identifier,
│                    identifier_prefix) + replicas map + apply_immediately + tags
├── locals.tf     — aliased cluster remote-state outputs
├── main.tf       — data.terraform_remote_state.rds_cluster
├── replicas.tf   — aws_rds_cluster_instance.replica (for_each) + preconditions
├── outputs.tf    — replica_identifiers, replica_endpoints (maps)
├── README.md / USAGE.md
├── tests/                 — plan-only gate (override_data stubs cluster state)
└── tests-localstack-pro/  — apply suite (S3-object fixture bridges real state)
```

### Resources

- `data.terraform_remote_state.rds_cluster` — the cluster state read.
- `aws_rds_cluster_instance.replica` with `for_each = var.replicas`:
  - `cluster_identifier = local.cluster_identifier`.
  - `identifier = "${var.identifier_prefix}-replica-${each.key}"`.
  - `instance_class = each.value.instance_class`.
  - `engine = local.engine`, `engine_version = local.engine_version_actual`
    (from remote state — drift-proof; see Q5).
  - `db_subnet_group_name = local.db_subnet_group_name`.
  - `db_parameter_group_name = local.db_parameter_group_name` (inherited;
    per-reader override is Q3).
  - `availability_zone = each.value.availability_zone` (null → auto).
  - `promotion_tier = each.value.promotion_tier` (failover priority; readers
    default to the lowest tier, 15, so they don't outrank the writer — Q2).
  - `publicly_accessible = each.value.publicly_accessible` (default false),
    `apply_immediately = var.apply_immediately`.
  - Optional per-reader settings (Q4 hybrid, all defaulted):
    `performance_insights_enabled`, `monitoring_interval` +
    `monitoring_role_arn`, `auto_minor_version_upgrade`.
  - `lifecycle` precondition: `local.cluster_identifier != null` (fail fast
    with a clear message if the remote state is missing the expected outputs
    — the cluster wasn't provisioned by DESIGN-0013's module, or the key is
    wrong — see Q7).

### Validation surface

- **Variable validations**: `identifier_prefix` regex
  (`^[a-z][a-z0-9-]{0,61}[a-z0-9]$`); `cluster_identifier` same RDS-identifier
  regex; each `replicas` key matches an identifier-safe pattern; each
  `promotion_tier` (if present) in `[0,15]`.
- **Preconditions** on `aws_rds_cluster_instance.replica`: the
  cluster-outputs-present guard (Q7); and, for any reader with
  `monitoring_interval > 0`, a `monitoring_role_arn != null` check (the Q4
  optional enhanced-monitoring setting). (Engine/version are inherited, so no
  cross-engine precondition is needed — that's the whole point of sourcing
  them from remote state.)

### Why a separate module

Restating DESIGN-0007's rationale (Q1), now that it's being built:

1. **Blast radius.** Adding/removing readers is more frequent than cluster
   lifecycle changes; a separate state means each reader change is one plan,
   one apply, one targeted radius — a bad reader can't roll back the cluster.
2. **Consumer ergonomics.** A team adding read scale authors their own
   read-replica instantiation without touching the cluster's source or its
   larger state file.
3. **Reader diversity.** Different pools want different `instance_class` / AZ
   / failover-tier; a module-per-pool is the natural factoring, and the
   `for_each` map makes intra-pool diversity first-class.

## API / Interface Changes

Greenfield module.

### Input surface

| Input | Type | Required? | Default |
|-------|------|-----------|---------|
| `region` | string | yes | — |
| `remote_state_bucket` | string | yes | — |
| `cluster_identifier` | string | yes | — (the cluster's stable id) |
| `identifier_prefix` | string | yes | — |
| `replicas` | map(object) | yes | — (empty map = zero readers) |
| `apply_immediately` | bool | no | false |
| `tags` | map(string) | no | {} |

The deliberately tiny surface mirrors proxy: DB-derived values (engine,
subnet group, parameter group, SG, KMS) are **not inputs** — they're read
from the cluster's remote state.

### Output surface

- `replica_identifiers` — `map(string)` keyed as `var.replicas`
  (`{ for k, r in aws_rds_cluster_instance.replica : k => r.identifier }`).
- `replica_endpoints` — `map(string)`, same keys (`… => r.endpoint`).

(The cluster's own `reader_endpoint` remains the load-balanced entry point;
these per-reader endpoints are for targeted routing.)

## Data Model

No application schema and no credentials of its own — the readers inherit the
cluster's master secret, KMS key, subnet group, and security group. The only
"model" is the `replicas` map keyed by stable identifier.

## Testing Strategy

Per RFC-0001, with the proxy module's remote-state technique:

- **`tests/` plan-only gate** — fake provider; `override_data` stubbing
  `data.terraform_remote_state.rds_cluster` outputs (cluster_identifier,
  engine, engine_version_actual, subnet-group, parameter-group). Runs:
  single-reader map (1 instance, name `…-replica-<key>`, engine inherited);
  three-reader map (3 instances, distinct keys, per-reader `instance_class` /
  AZ / `promotion_tier` plumb through); empty map `{}` → zero instances;
  key-stability (removing a middle key doesn't renumber others — assert
  identifiers by key); and `validation.tftest.hcl` negatives (bad
  identifier, bad `cluster_identifier`, out-of-range `promotion_tier`,
  missing cluster outputs → the Q7 precondition via
  `override_data` with a null `cluster_identifier`).
- **Apply suite** — because reader instances are Aurora and need a real
  cluster to attach to, the apply must bridge remote state through a **real
  S3-object fixture** (the proxy `tests-localstack-pro/fixtures/db` pattern):
  a `setup` run stands up an Aurora cluster + writes stub cluster state to
  S3, then `apply_replicas` attaches readers and asserts count/identifiers.
  This lands in **`tests-localstack-pro/`** (Aurora + cross-state bridging is
  the Pro-tier surface), with a Community-safe `plan_smoke` in
  `tests-localstack/`. 501s follow the IMPL-0005 Phase 9 fall-back;
  the macOS named-volume caveat applies (embedded Postgres).

## Migration / Rollout Plan

Greenfield; ships **fourth and last** in the DESIGN-0007 order — it **must
merge after `cluster`** (DESIGN-0013), whose remote-state output names are
this module's hard dependency. Steps: scaffold the small file set → wire the
cluster remote-state read (proxy pattern) → plan-only tests with
`override_data` → Pro apply suite with the S3-object fixture (+ FINDINGS) →
USAGE + README regen → mark Implemented. The cluster module's README gains a
"scaling out" pointer to this module.

## Open Questions

All seven questions were resolved 2026-07-09. Each heading records the chosen
option; the **Resolved** line states the decision, and the alternatives are
retained for the record.

### Q1 — Cluster-only, or parameterise the target (cluster vs serverless)? — RESOLVED (a)

**Resolved: a.** Cluster-only for v1 — the `rds/cluster/` state-key segment is
hardcoded; no `target_type` input. A future DESIGN can generalise to
serverless targets.

- **a (chosen):** **Cluster-only for v1.** Hardcode the
  `rds/cluster/` state-key segment. Aurora Serverless v2 (the `serverless`
  module) scales *compute* automatically and rarely needs manually-added
  readers; keeping the target fixed is the simplest correct thing. A future
  DESIGN can generalise if a real consumer wants serverless readers.
- **b:** **Parameterise `var.target_type`** (`aurora-cluster` | `serverless`)
  with a `target_dir_map` exactly like the proxy module — one module attaches
  readers to either Aurora cluster kind. More flexible and symmetric with
  proxy, but adds surface (and validation that serverless targets accept
  provisioned readers) before there's a consumer.
- **other:** ______

### Q2 — Per-reader promotion tier (failover priority) — RESOLVED (a)

**Resolved: a.** Expose `promotion_tier` in the `replicas` object (optional,
default `15` — lowest priority, so readers don't outrank the writer);
operators can mark a preferred failover target with `0`/`1`.

- **a (chosen):** Expose `promotion_tier` in the `replicas` object
  (optional, **default `15`** — the lowest priority, so readers don't get
  promoted ahead of a deliberately-tiered reader, and the writer stays
  authoritative). Lets an operator mark a specific reader as the preferred
  failover target (`0`/`1`).
- **b:** Omit it — let AWS default all readers to tier 1. Smaller surface,
  but no control over which reader is promoted on writer failure.
- **c:** A single module-level `promotion_tier` for the whole pool — simpler
  than per-reader, but loses the diversity that motivates the map.
- **other:** ______

### Q3 — Per-reader parameter group override — RESOLVED (a)

**Resolved: a.** Every reader inherits the cluster's `db_parameter_group_name`
from remote state; no per-reader override (keeps readers consistent with the
cluster, surface minimal).

- **a (chosen):** **Inherit** the cluster's `db_parameter_group_name`
  from remote state for every reader; no per-reader override. Keeps readers
  consistent with the cluster and the surface minimal.
- **b:** Allow an optional `db_parameter_group_name` per reader in the map —
  enables reader-specific tuning (e.g. a reporting reader with different
  work_mem), at the cost of drift risk and a bigger object.
- **other:** ______

### Q4 — `replicas` object shape — RESOLVED (a + b hybrid)

**Resolved: a + b (hybrid).** The object requires only `instance_class` (a's
minimal core), and exposes **b**'s richer settings as **optional** attributes
with sensible defaults: `availability_zone`, `promotion_tier` (default 15),
`performance_insights_enabled` (default false), `monitoring_interval` (default
0) + `monitoring_role_arn`, `auto_minor_version_upgrade` (default true),
`publicly_accessible` (default false). A caller passes just `instance_class`
for the common case, or opts into the advanced knobs per reader. The updated
`replicas` object under "The replicas map" reflects this.

- **a (chosen as the required core):** `{ instance_class (req),
  availability_zone (opt), promotion_tier (opt, default 15) }` — the minimal
  useful set covering sizing, AZ pinning, and failover priority.
- **b (chosen as optional settings):** the richer fields
  (`performance_insights_enabled`, `monitoring_interval` +
  `monitoring_role_arn`, `auto_minor_version_upgrade`, `publicly_accessible`)
  are layered on as **optional** attributes with defaults — available without
  forcing a wide object on the common case.
- **c:** A **minimal** object of just `instance_class` (AZ + tier as
  module-level values applied to all) — smallest, but no intra-pool
  diversity.
- **other:** ______

### Q5 — Source engine version from the cluster, or leave it to Aurora? — RESOLVED (a)

**Resolved: a.** Pin `engine_version = local.engine_version_actual` from the
cluster's remote state — explicit, drift-proof, and visible in the reader's
plan.

- **a (chosen):** **Pin `engine_version = local.engine_version_actual`**
  from the cluster's remote state. Explicit, drift-proof, and makes the plan
  show the exact version each reader runs — matches the DESIGN-0007 "single
  source of truth, replica drift impossible" intent.
- **b:** **Omit `engine_version`** on the reader and let Aurora inherit it
  from the cluster implicitly. Slightly less code, but the version isn't
  visible in the reader's plan and relies on AWS's implicit inheritance.
- **other:** ______

### Q6 — Aurora replica auto-scaling — RESOLVED (a)

**Resolved: a.** Aurora replica auto-scaling is out of scope for v1; the
`replicas` map is explicit. Design elastic readers later (possibly a separate
module) if a consumer needs them.

- **a (chosen):** **Out of scope for v1.** The `replicas` map is
  explicit — operators add/remove readers deliberately. Target-tracking
  auto-scaling (`aws_appautoscaling_target` / `_policy` on the cluster's
  reader count) is a separate concern that fights an explicit map; design it
  later (possibly its own module) if a consumer needs elastic readers.
- **b:** Add optional auto-scaling resources gated behind a
  `var.autoscaling` object — elastic readers in one module, but it conflicts
  conceptually with the explicit `for_each` map (who owns reader count?) and
  needs careful `ignore_changes` handling.
- **other:** ______

### Q7 — Guard against stale / wrong cluster remote state — RESOLVED (a)

**Resolved: a.** Add a `lifecycle.precondition` on the reader asserting the
required cluster outputs are non-null (e.g. `local.cluster_identifier !=
null`), with a message naming the expected state key — fail fast and legibly.

- **a (chosen):** Add a **`lifecycle.precondition`** on the reader
  asserting the required cluster outputs are non-null (e.g.
  `local.cluster_identifier != null`), with a message naming the expected
  state key — fails fast and legibly when the cluster wasn't built by the
  DESIGN-0013 module or `cluster_identifier` is wrong. (Same spirit as the
  proxy V2/V4/V5 preconditions on remote-state values.)
- **b:** Rely on the natural error when `data.terraform_remote_state`
  resolves a missing output — less code, but a cryptic failure far from the
  root cause.
- **c:** Both — precondition **and** a note in the README on what happens if
  the cluster is destroyed/recreated (its `cluster_resource_id` changes,
  forcing reader replacement on the next apply).
- **other:** ______

## References

- [DESIGN-0007](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module family layout (parent design; Q1 `for_each` resolution).
- [DESIGN-0013](0013-rds-aurora-provisioned-cluster-module.md) — Aurora provisioned cluster (the source-of-truth state this module consumes; must merge first).
- [DESIGN-0010](0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md) — RDS Proxy module (the reference remote-state-composition + S3-fixture test pattern this module mirrors).
- [IMPL-0010](../impl/0010-rds-proxy-module-implementation.md) — RDS Proxy implementation (the `tests-localstack-pro/fixtures/db` S3-object bridge this module's apply suite reuses).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state`.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [`aws_rds_cluster_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance).
