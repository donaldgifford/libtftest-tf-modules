---
id: DESIGN-0010
title: "RDS Proxy module for the RDS and Aurora data tier"
status: Implemented
author: Donald Gifford
created: 2026-06-29
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0010: RDS Proxy module for the RDS and Aurora data tier

**Status:** Implemented
**Author:** Donald Gifford
**Date:** 2026-06-29

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module placement and decomposition](#module-placement-and-decomposition)
  - [Composition via remote state](#composition-via-remote-state)
  - [Resource topology](#resource-topology)
  - [Authentication and secret reuse](#authentication-and-secret-reuse)
  - [Engine to engine-family mapping](#engine-to-engine-family-mapping)
  - [Variable assertions and validations](#variable-assertions-and-validations)
  - [Connection-pool configuration](#connection-pool-configuration)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Q1 — Proxy delivery: standalone module vs in-module toggle — RESOLVED (a)](#q1--proxy-delivery-standalone-module-vs-in-module-toggle--resolved-a)
  - [Q2 — One proxy module vs separate rds-proxy and aurora-proxy — RESOLVED (a)](#q2--one-proxy-module-vs-separate-rds-proxy-and-aurora-proxy--resolved-a)
  - [Q3 — Proxy auth secret source — RESOLVED (a)](#q3--proxy-auth-secret-source--resolved-a)
  - [Q4 — Client-to-proxy IAM authentication default — RESOLVED (a)](#q4--client-to-proxy-iam-authentication-default--resolved-a)
  - [Q5 — Aurora read-only proxy endpoint — RESOLVED (a)](#q5--aurora-read-only-proxy-endpoint--resolved-a)
  - [Q6 — TLS enforcement default — RESOLVED (a)](#q6--tls-enforcement-default--resolved-a)
  - [Q7 — Connection-pool tuning surface — RESOLVED (a)](#q7--connection-pool-tuning-surface--resolved-a)
  - [Q8 — Proxy engine-compatibility validation depth — RESOLVED (a)](#q8--proxy-engine-compatibility-validation-depth--resolved-a)
  - [Q9 — MySQL in v1 or defer — RESOLVED (a)](#q9--mysql-in-v1-or-defer--resolved-a)
  - [Q10 — tests-localstack tier and LocalStack Pro — RESOLVED (a)](#q10--tests-localstack-tier-and-localstack-pro--resolved-a)
  - [Q11 — Relationship to DESIGN-0007 and rollout sequencing — RESOLVED (a)](#q11--relationship-to-design-0007-and-rollout-sequencing--resolved-a)
- [References](#references)
<!--toc:end-->

## Overview

A single standalone Terraform module, **`modules/rds/proxy`**, that places an
[Amazon RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html)
in front of any of the data-tier modules designed in
[DESIGN-0007](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md)
(`instance`, `cluster`, `serverless`). The proxy provides managed connection
pooling, IAM-mediated authentication, and faster failover for
connection-churning consumers (Lambda, short-lived EKS pods). It composes
against the target DB module's remote state — reusing the AWS-managed master
secret, subnet group, and KMS key the DB module already emits — and is engine-
aware across **Postgres** and **MySQL**.

This document covers the proxy concern only. The underlying RDS instance and
Aurora cluster modules are already designed in DESIGN-0007 (which explicitly
filed RDS Proxy as a deferred follow-up); this is that follow-up. The detailed
design below reflects the **recommended (option a)** resolution of every open
question; the [Open Questions](#open-questions) section captures each decision
for review and may revise the design.

## Goals and Non-Goals

### Goals

- **Connection pooling + failover resilience for the data tier.** The proxy
  multiplexes client connections onto a managed pool, sheds load predictably
  under surges, and re-points to a promoted standby/writer on failover without
  the client re-resolving DNS. This is the value DESIGN-0007's bare
  endpoints don't provide.
- **Reuse the DB module's AWS-managed master secret.** DESIGN-0007 defaults
  to `manage_master_user_password = true`; the secret it produces is
  `{username, password}` JSON — exactly what RDS Proxy's `auth.secret_arn`
  consumes. The proxy module reads the target's `master_user_secret_arn` from
  remote state, so **no new secret is minted** (Q3-a).
- **Match the fleet's composition conventions.** Standalone module composed
  via `data.terraform_remote_state` (ADR-0001), separate blast radius (the
  read-replica precedent), module-managed security group, module-managed IAM
  role, plan-time invariants via `terraform test` (ADR-0013). One proxy
  module serves all target types via a `var.target_type` discriminator (Q1-a,
  Q2-a).
- **Multi-engine surface (Postgres + MySQL).** `engine_family` is derived from
  the target engine read from remote state; the resource graph is identical
  across engines (Q9-a).
- **Validation-first variable surface.** The module is dense with
  `validation` blocks and `lifecycle.precondition`s asserting the coherence
  the operator asked for: engine ↔ `engine_family`, `target_type` ↔ the right
  identifier, read-only endpoint only on Aurora, proxy-supported engine, and
  the multi-AZ / replica / serverless interactions documented below.
- **Secure-by-default.** `require_tls = true` by default (Q6-a); optional
  client-to-proxy IAM auth (Q4); proxy is never publicly accessible (an AWS
  constraint, not just a default).

### Non-Goals

- **SQL Server and MariaDB.** RDS Proxy's `engine_family` supports `SQLSERVER`
  and MariaDB runs under `MYSQL`, but both engines are out of fleet scope per
  DESIGN-0007 Non-Goals. Adding them is additive (a validation entry + an
  `engine_family` map row).
- **Cross-VPC proxy endpoints.** v1 keeps the proxy in the target DB's VPC.
  Aurora cross-VPC access via an additional endpoint with a different VPC is a
  follow-up.
- **App-user / role / GRANT provisioning.** The proxy authenticates as the
  master user via the managed secret in v1. Provisioning a least-privilege
  application DB user + its own secret is out-of-band schema management (same
  posture as DESIGN-0007 and
  [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md)).
  See Q3-b for the hardening path.
- **Multiple targets per proxy.** AWS binds one proxy to exactly one target DB
  instance or cluster. Fan-out (one proxy, many DBs) is not a thing; the
  inverse (many proxies, one DB) is allowed but not modeled in v1.
- **Aurora Serverless v1.** Unsupported by RDS Proxy. The `serverless` module
  is v2 only, so this is moot, but worth stating.
- **Read-routing across non-Aurora read replicas.** AWS attaches a proxy only
  to the **writer** instance, never to an RDS read replica. Reader routing
  exists only for Aurora, via a `READ_ONLY` proxy endpoint (Q5).
- **Custom DNS / SSL-hostname validation.** RDS Proxy can't be used with
  custom DNS when SSL hostname validation is on; out of scope.

## Background

DESIGN-0007 laid out four sibling modules under `modules/rds/` — `instance`
(single `aws_db_instance`), `cluster` (Aurora provisioned, single-writer
default), `read-replica`, and `serverless` (Aurora Serverless v2). Only
`serverless` is implemented today (IMPL-0007); `instance` and `cluster` are
designed-but-not-shipped per the DESIGN-0007 rollout plan.

DESIGN-0007 deliberately filed RDS Proxy as a **Non-Goal** ("the proxy lives
at a different layer … files as a follow-up module if/when needed") and
anticipated its composition shape ("any future RDS-adjacent module like a
proxy module" consuming the cluster's remote-state outputs). This design is
that follow-up and supersedes that single Non-Goal line.

Load-bearing RDS Proxy facts gathered for this design (June 2026):

- **Engines.** RDS Proxy supports RDS for MySQL/PostgreSQL/MariaDB/SQL Server
  and Aurora MySQL/PostgreSQL. `engine_family` ∈ {`MYSQL`, `POSTGRESQL`,
  `SQLSERVER`}. Our scope maps Postgres → `POSTGRESQL`, MySQL → `MYSQL`.
- **Aurora Serverless v2 is supported** (v1 is not). Two operational caveats:
  (1) RDS Proxy on Serverless v2 carries a **minimum 8-ACU billing floor**
  (the `Proxy-ASv2-Usage` line) — materially more expensive than on
  provisioned instances; (2) an attached proxy keeps connections open and
  therefore **prevents the zero-ACU auto-pause** idle behavior.
- **Auth.** The proxy authenticates to the DB using a Secrets Manager secret
  (`{username, password}` JSON) **or** end-to-end IAM. The AWS-managed master
  secret from `manage_master_user_password` is directly usable as the proxy
  `secret_arn`; the proxy's IAM role then needs `secretsmanager:GetSecretValue`
  on that ARN plus `kms:Decrypt` on its CMK.
- **Topology constraints.** Proxy must be in the DB's VPC, can't be publicly
  accessible, can't use `dedicated` VPC tenancy. One proxy → one target. For
  Aurora, read-only routing is a separate `aws_db_proxy_endpoint` with
  `target_role = READ_ONLY`; the default endpoint is writer (`READ_WRITE`).
- **LocalStack.** RDS Proxy is a **Pro-tier** feature (native RDS provider in
  v4.4; `CreateDBProxyEndpoint` in v4.5). Community does not emulate it. This
  diverges from DESIGN-0007's Q7 posture (RDS modules default to Community)
  and drives Q10.

All four modules sit on the fleet pin `hashicorp/aws ~> 6.2`; the proxy
resources (`aws_db_proxy`, `aws_db_proxy_default_target_group`,
`aws_db_proxy_target`, `aws_db_proxy_endpoint`) are all available there.

## Detailed Design

### Module placement and decomposition

```text
modules/
└── rds/
    ├── instance/        — DESIGN-0007 (single aws_db_instance)
    ├── cluster/         — DESIGN-0007 (Aurora provisioned)
    ├── read-replica/    — DESIGN-0007
    ├── serverless/      — IMPL-0007 (Aurora Serverless v2, shipped)
    └── proxy/           — THIS DESIGN (RDS Proxy in front of any target)
```

`modules/rds/proxy` is a standalone source module (Q1-a) carrying the standard
scaffolding (`versions.tf` pinned `~> 6.2` / `>= 1.1`, `.terraform-docs.yml`,
`.tflint.hcl`, `README.md` stub, generated `USAGE.md`, `tests/`,
`tests-localstack/`). A single module handles both RDS-instance and
Aurora-cluster (and serverless) targets via `var.target_type` (Q2-a) rather
than forking `instance-proxy` / `cluster-proxy`, because the resource graph is
identical bar one attribute on `aws_db_proxy_target`.

### Composition via remote state

The proxy reads its target's state, following the read-replica precedent and
the fleet's S3 key convention. `var.target_type` selects which key shape and
which outputs to read:

```hcl
# target_type = "rds-instance"  -> ${region}/rds/instance/${target_identifier}/terraform.tfstate
# target_type = "aurora-cluster" -> ${region}/rds/cluster/${target_identifier}/terraform.tfstate
# target_type = "serverless"     -> ${region}/rds/serverless/${target_identifier}/terraform.tfstate
data "terraform_remote_state" "target" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/rds/${local.target_dir}/${var.target_identifier}/terraform.tfstate"
    region = var.region
  }
}
```

Outputs consumed from the target module (all present in DESIGN-0007's output
contract, plus the network outputs the proxy needs):

| From target remote state | Used for |
|--------------------------|----------|
| `master_user_secret_arn` | proxy `auth.secret_arn` + IAM `GetSecretValue` resource |
| `kms_key_arn` / `kms_key_id` | proxy IAM `kms:Decrypt` resource (secret CMK) |
| `engine`, `engine_version_actual` | `engine_family` derivation + validation |
| `db_subnet_group_name` → subnet IDs, or `database_subnet_ids` | `aws_db_proxy.vpc_subnet_ids` |
| `instance_identifier` (rds-instance) | `aws_db_proxy_target.db_instance_identifier` |
| `cluster_identifier` (aurora-cluster / serverless) | `aws_db_proxy_target.db_cluster_identifier` |
| `vpc_id` | proxy security-group placement |

> **Note — output gap (links to Q11):** DESIGN-0007's `instance` output set
> emits `db_subnet_group_name` but not raw `database_subnet_ids`; the proxy
> needs subnet IDs for `vpc_subnet_ids`. Either DESIGN-0007's modules add a
> `db_subnet_ids` output, or the proxy re-reads the VPC remote state directly
> (it already takes `remote_state_bucket` + `region`). Recommended: add the
> small output to the DB modules so the proxy has a single upstream. Tracked
> in Q11.

### Resource topology

```text
aws_iam_role.proxy            (trust: rds.amazonaws.com)
  └─ aws_iam_role_policy       (GetSecretValue on master secret ARN
                                + kms:Decrypt on its CMK)
aws_security_group.proxy       (egress to DB SG on engine port;
                                ingress from var.allowed_consumer_sg_ids)
aws_db_proxy.this              (engine_family, role_arn, vpc_subnet_ids,
                                vpc_security_group_ids, require_tls,
                                idle_client_timeout, auth { secret_arn,
                                iam_auth, auth_scheme = "SECRETS" })
aws_db_proxy_default_target_group.this
                               (connection_pool_config { ... })
aws_db_proxy_target.this       (db_instance_identifier XOR db_cluster_identifier)
aws_db_proxy_endpoint.read_only[0]   (Aurora only, gated — target_role = READ_ONLY)
```

Notes:

- **Security group.** The proxy gets its own SG; the DB module's SG must allow
  ingress from the proxy SG. v1 expects the operator to pass the proxy SG into
  the DB module's `allowed_consumer_sg_ids` (the proxy SG id is a module
  output) — i.e. the proxy is just another consumer of the DB tier. Documented
  in the README; no circular dependency because the SG ids flow DB→proxy via
  remote state and proxy→DB via a subsequent DB-module apply or a pre-created
  SG. (This ordering wrinkle is called out in Q11.)
- **`aws_db_proxy_target`** uses `db_instance_identifier` for `rds-instance`
  and `db_cluster_identifier` for `aurora-cluster` / `serverless`, selected by
  `var.target_type`. Exactly one is set.
- **Read-only endpoint** is `count`-gated on
  `var.create_read_only_endpoint && var.target_type != "rds-instance"` (Q5-a).

### Authentication and secret reuse

Default (Q3-a): the proxy's `auth.secret_arn` is the target's
`master_user_secret_arn` from remote state. The module-managed IAM role grants:

```hcl
# secretsmanager:GetSecretValue on the master secret ARN
# kms:Decrypt on the secret's CMK (kms_key_arn from remote state),
#   conditioned to via:secretsmanager
```

Client-to-proxy auth (Q4): `var.require_iam_auth` (default `false`) maps to
`auth.iam_auth = "REQUIRED" | "DISABLED"`. When `true`, the consumer obtains a
token via `aws rds generate-db-auth-token` against the proxy endpoint; this
composes with — and is gated by — the target having
`iam_database_authentication_enabled = true` (a `precondition` asserts this).

### Engine to engine-family mapping

A static `locals.tf` map (same posture as DESIGN-0007 Q3's parameter-family
map) derives `engine_family` from the target engine read from remote state:

| Target `engine` | `engine_family` | default port |
|-----------------|-----------------|:------------:|
| `postgres` | `POSTGRESQL` | 5432 |
| `aurora-postgresql` | `POSTGRESQL` | 5432 |
| `mysql` | `MYSQL` | 3306 |
| `aurora-mysql` | `MYSQL` | 3306 |

Deriving from remote state (not a caller input) makes engine drift between the
proxy and its target impossible by construction — the same single-source-of-
truth property the read-replica module relies on.

### Variable assertions and validations

This is the operator-requested core. Validations split across `variable`
`validation` blocks (static, single-variable) and `lifecycle.precondition`s on
`aws_db_proxy.this` (cross-variable / remote-state-dependent):

| # | Assertion | Mechanism | Rationale |
|---|-----------|-----------|-----------|
| V1 | `target_type ∈ {rds-instance, aurora-cluster, serverless}` | `variable validation` | discriminator hygiene |
| V2 | target `engine ∈ {postgres, mysql, aurora-postgresql, aurora-mysql}` | `precondition` (engine from remote state) | proxy-supported engine only (Q8-a: family-level) |
| V3 | `create_read_only_endpoint` ⇒ `target_type != rds-instance` | `precondition` | proxy attaches to writer only; RDS has no proxy reader routing |
| V4 | `require_iam_auth` ⇒ target `iam_database_authentication_enabled` | `precondition` | IAM client auth needs IAM enabled on the engine |
| V5 | `auth_secret_arn` present (from remote state) XOR end-to-end IAM configured | `precondition` | a proxy must have some auth path |
| V6 | `max_connections_percent ∈ [1,100]`, `max_idle_connections_percent ∈ [0,max_connections_percent]` | `variable validation` + `precondition` | coherent pool config |
| V7 | `connection_borrow_timeout >= 0` | `variable validation` | — |

Related coherence the operator named, enforced in the **DB** modules
(DESIGN-0007 surface, extended here) rather than the proxy:

- **multi-AZ.** `instance` keeps `var.multi_az`; `serverless` already rejects
  `multi_az` (Serverless v2 has no such concept — a DESIGN-0007 validation
  negative). The proxy is multi-AZ by construction (spans ≥2 AZs from its
  subnets) regardless of the target's `multi_az`.
- **multiple read replicas.** A precondition/README note: a proxy in front of
  an `instance` + RDS read replicas routes **only to the writer**; consumers
  wanting replica read traffic must target the replica endpoints directly, or
  use Aurora + a `READ_ONLY` proxy endpoint. The module does not silently
  imply read load-balancing.

### Connection-pool configuration

`aws_db_proxy_default_target_group.connection_pool_config` inputs (Q7-a —
expose the load-bearing knobs with sane defaults; leave advanced ones
optional):

| Input | Default | Notes |
|-------|:-------:|-------|
| `max_connections_percent` | 100 | % of DB `max_connections` the pool may use |
| `max_idle_connections_percent` | 50 | warm-but-idle ceiling |
| `connection_borrow_timeout` | 120 | seconds to wait for a pooled conn before shedding |
| `session_pinning_filters` | `[]` | advanced; `EXCLUDE_VARIABLE_SETS` etc. |
| `init_query` | `null` | advanced; per-connection init (e.g. `SET ROLE`) |

## API / Interface Changes

Greenfield module. Input surface (recommended-option shape):

| Input | Type | Required? | Default |
|-------|------|-----------|---------|
| `region` | string | yes | — |
| `remote_state_bucket` | string | yes | — |
| `target_type` | string | yes | — (`rds-instance` / `aurora-cluster` / `serverless`) |
| `target_identifier` | string | yes | — (DB module's stable id / state key) |
| `name` | string | yes | — (proxy name) |
| `allowed_consumer_sg_ids` | list(string) | no | `[]` |
| `require_tls` | bool | no | `true` (Q6) |
| `require_iam_auth` | bool | no | `false` (Q4) |
| `idle_client_timeout` | number | no | `1800` |
| `create_read_only_endpoint` | bool | no | `false` (Q5; Aurora only) |
| `max_connections_percent` | number | no | `100` |
| `max_idle_connections_percent` | number | no | `50` |
| `connection_borrow_timeout` | number | no | `120` |
| `session_pinning_filters` | list(string) | no | `[]` |
| `init_query` | string | no | `null` |
| `debug_logging` | bool | no | `false` |
| `tags` | map(string) | no | `{}` |

Outputs:

| Output | Notes |
|--------|-------|
| `proxy_arn`, `proxy_name` | the `aws_db_proxy` |
| `proxy_endpoint` | default (writer) endpoint — feeds consumer connection strings |
| `read_only_endpoint` | the `READ_ONLY` endpoint (Aurora, when created), else `null` |
| `proxy_security_group_id` | pass into the DB module's `allowed_consumer_sg_ids` |
| `proxy_role_arn` | the module-managed IAM role |

## Data Model

No application schema. The module models the RDS Proxy API surface plus its
dependencies (IAM role, SG, the target's secret/subnets/identifier read from
remote state). Credentials are the AWS-managed master secret by default
(Q3-a); the proxy never stores or emits a password — only the secret ARN flows
through, and only into AWS's own auth config.

## Testing Strategy

Per [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
and [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md):

- **`terraform test` plan-only suite (`tests/`)** — the primary gate, and
  where the operator-requested assertions are exercised. `override_data` stubs
  the target's remote-state outputs (engine, secret ARN, identifier, subnets)
  so no live DB is needed. Cases:
  - Default shapes per `target_type` × engine (rds-instance/postgres,
    rds-instance/mysql, aurora-cluster/aurora-postgresql, …): resource counts,
    `engine_family` derivation, `db_instance_identifier` vs
    `db_cluster_identifier` selection.
  - Validation negatives: V1–V7 above — bad `target_type`, read-only endpoint
    on `rds-instance` (V3), `require_iam_auth` without IAM-enabled target (V4),
    `max_idle > max_connections` (V6), unsupported engine (V2).
  - Read-only endpoint present iff `create_read_only_endpoint && Aurora`.
- **`tests-localstack` apply suite** — **Pro-gated** (Q10). RDS Proxy is
  Pro-only in LocalStack; the suite is marked accordingly and documents the
  gap in `FINDINGS.md` for Community runs (falls back to `plan_smoke`, per the
  IMPL-0005 Phase 9 pattern). On Pro, exercises `aws_db_proxy` +
  `default_target_group` + `target` + (Aurora) `endpoint` against a
  LocalStack-provisioned target.
- **Manual post-apply smoke (operator, not CI):** connect through the proxy
  endpoint with the master secret; for Aurora, confirm the `READ_ONLY`
  endpoint routes to a reader. README documents the recipe.

## Migration / Rollout Plan

Greenfield module; no existing consumers.

1. **Resolve the open questions below** (especially Q1, Q2, Q11) — they
   determine module count and whether DB-module outputs need extending.
2. **Target `serverless` first.** It is the only DESIGN-0007 module shipped
   today, so it's the only live target. Implementing the proxy against
   `serverless` validates the remote-state contract end-to-end (mindful of the
   Serverless v2 8-ACU cost floor — call it out in the README).
3. **Extend to `instance` / `cluster`** as those ship per DESIGN-0007's
   rollout. If Q11-b is chosen, bundle implementing `instance` + `cluster`
   into this work so there's a provisioned target from day one.
4. Own IMPL doc + feature branch + PR, same cadence as prior modules.

## Open Questions

All eleven questions resolved 2026-06-29 (option **a** across the board) and
folded into the sections above. Each resolution and the alternative it
displaced is recorded below.

### Q1 — Proxy delivery: standalone module vs in-module toggle — RESOLVED (a)

**Resolved (a):** a standalone `modules/rds/proxy` composed via remote state
against the target DB module's outputs. Matches ADR-0001 and the read-replica
precedent — separate plan, separate blast radius, proxy lifecycle decoupled
from DB lifecycle, and the proxy sub-system (IAM role, SG, target group,
endpoints) stays out of the DB modules' input surfaces. The in-module
`var.enable_proxy` toggle (b) — closest to the "option to be selected"
phrasing — was rejected because it couples proxy churn to DB churn and
triples the proxy code across three DB modules.

### Q2 — One proxy module vs separate rds-proxy and aurora-proxy — RESOLVED (a)

**Resolved (a):** one `modules/rds/proxy` with a `var.target_type`
discriminator (`rds-instance` / `aurora-cluster` / `serverless`). Two
near-identical `instance-proxy` / `cluster-proxy` modules (b) were rejected —
the resource graph differs only in the `aws_db_proxy_target` identifier
attribute. (The "2 modules" originally referenced — RDS vs Aurora — already
exist as DESIGN-0007's `instance` and `cluster`; the proxy is a third concern
layered on either.)

### Q3 — Proxy auth secret source — RESOLVED (a)

**Resolved (a):** reuse the target's AWS-managed master secret
(`master_user_secret_arn` from remote state) as the proxy `auth.secret_arn` —
zero new secrets, confirmed `{username,password}`-compatible, AWS-rotated. The
dedicated application-user secret (b) and end-to-end IAM (c) remain documented
hardening paths for a follow-up, not v1. The proxy IAM role gets
`secretsmanager:GetSecretValue` + `kms:Decrypt` on that secret/CMK.

### Q4 — Client-to-proxy IAM authentication default — RESOLVED (a)

**Resolved (a):** `var.require_iam_auth` defaults to `false` (password flow
keeps working); opt-in to IAM-required, gated by precondition V4 on the
target's `iam_database_authentication_enabled`. Default-`true` (b) was
rejected as too disruptive for v1 consumers.

### Q5 — Aurora read-only proxy endpoint — RESOLVED (a)

**Resolved (a):** optionally create a `READ_ONLY` `aws_db_proxy_endpoint` via
`var.create_read_only_endpoint` (default `false`), valid only for
`aurora-cluster` (precondition V3 rejects it for `rds-instance`, which has no
proxy reader routing). Writer-only-in-v1 (b) was rejected — the endpoint is
cheap to ship and Aurora consumers want pooled reads.

### Q6 — TLS enforcement default — RESOLVED (a)

**Resolved (a):** `require_tls = true` by default (enforce encrypted
client→proxy connections), overridable. Default-`false` (b) rejected — secure
transport is the fleet default.

### Q7 — Connection-pool tuning surface — RESOLVED (a)

**Resolved (a):** expose `max_connections_percent` (100),
`max_idle_connections_percent` (50), and `connection_borrow_timeout` (120) as
inputs with defaults; keep `session_pinning_filters` and `init_query` as
advanced optional inputs. Exposing nothing (b) rejected — these are the knobs
operators actually reach for under load.

### Q8 — Proxy engine-compatibility validation depth — RESOLVED (a)

**Resolved (a):** validate engine **family** only (postgres/aurora-postgresql
→ `POSTGRESQL`; mysql/aurora-mysql → `MYSQL`; reject anything else). No engine-
**version** support matrix (b) — it's region/version dependent and drifts;
AWS rejects unsupported versions at apply with a clear error, documented in
the README.

### Q9 — MySQL in v1 or defer — RESOLVED (a)

**Resolved (a):** design the full Postgres + MySQL surface now; implement and
test **Postgres first**, then MySQL as a fast-follow phase in the same IMPL
(only `engine_family`/port differ). Neither a Postgres-only design (b) nor a
both-at-once v1 (c) — the surface is multi-engine from day one, the
implementation is sequenced.

### Q10 — tests-localstack tier and LocalStack Pro — RESOLVED (a)

**Resolved (a):** the plan-only `tests/` suite (ADR-0013) is the always-on
gate and covers every validation without AWS; the `tests-localstack/` apply
suite is **Pro-gated** (RDS Proxy is Pro-only in LocalStack), falling back to
`plan_smoke` + a `FINDINGS.md` note on Community. This makes the proxy the
fleet's first genuinely Pro-requiring module — a deliberate, documented
divergence from DESIGN-0007 Q7. Plan-only-only (b) rejected — the apply path is
worth covering where Pro is available.

### Q11 — Relationship to DESIGN-0007 and rollout sequencing — RESOLVED (a)

**Resolved (a):** DESIGN-0010 is a focused follow-up superseding DESIGN-0007's
"RDS Proxy = Non-Goal" line. Implement the proxy against the already-shipped
`serverless` module first, then validate against `instance` / `cluster` as
they ship per DESIGN-0007's rollout. The DB modules gain a small
`db_subnet_ids` output so the proxy has a single upstream (the output-gap note
in Detailed Design). Bundling the `instance` + `cluster` implementations into
this work (b) was rejected to keep scope tight; folding back into DESIGN-0007
(c) is moot given the separate-doc decision.

## References

- [DESIGN-0007](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS/Aurora module layout (the foundation; deferred RDS Proxy to this follow-up).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state` (drives the target↔proxy composition).
- [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) — Terraform manages AWS API resources only; user/schema provisioning is out-of-band (Q3-b rationale).
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants (the validation suite).
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [INV-0002](../investigation/0002-fleet-wide-localstack-pro-auto-detection-harness-for-tests.md) — Fleet-wide LocalStack Pro auto-detection (relevant to Q10).
- [Amazon RDS Proxy — User Guide](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html) — engines, quotas, limitations.
- [Amazon RDS Proxy for Aurora](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy.html) — Serverless v2 support + reader endpoints.
- [Setting up database credentials for RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-secrets-arns.html) — secret format + managed-secret reuse (Q3).
- [`aws_db_proxy` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_proxy) — `engine_family`, `auth` block, `require_tls`.
- [LocalStack 4.4 release](https://blog.localstack.cloud/localstack-release-v-4-4-0/) / [4.5 release](https://blog.localstack.cloud/localstack-release-v-4-5-0/) — native RDS provider + DB Proxy Endpoints (Q10).
