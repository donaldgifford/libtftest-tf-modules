---
id: IMPL-0010
title: "RDS Proxy module implementation"
status: Completed
author: Donald Gifford
created: 2026-06-29
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0010: RDS Proxy module implementation

**Status:** Completed
**Author:** Donald Gifford
**Date:** 2026-06-29

> **Verification status.** All 12 phases implemented and committed. Every gate
> runnable in the build environment is green: `just tf all rds/proxy` (validate,
> tflint-clean, fmt, and 20/20 plan-only tests across Postgres and MySQL) and the
> Community-safe `just tf test-localstack rds/proxy` (`plan_smoke`, offline).
> The **one** unverified item is the live **LocalStack-Pro apply**
> (`tests-localstack-pro/apply_pro.tftest.hcl`): it is `terraform validate` /
> parse / plan-valid but was **not executed** in this environment (no LocalStack
> Pro container / `LOCALSTACK_AUTH_TOKEN` / Docker). Run
> `just tf test-localstack-pro rds/proxy` against a Pro container to close it —
> tracked in the module's `tests-localstack/FINDINGS.md` and Phase 10.

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module scaffolding, version pins, and variable surface](#phase-1-module-scaffolding-version-pins-and-variable-surface)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: DB-module output prerequisite for proxy composition](#phase-2-db-module-output-prerequisite-for-proxy-composition)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Remote-state composition and engine-family locals](#phase-3-remote-state-composition-and-engine-family-locals)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Proxy IAM role and secret-access policy](#phase-4-proxy-iam-role-and-secret-access-policy)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Proxy security group](#phase-5-proxy-security-group)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: RDS Proxy core resources and preconditions](#phase-6-rds-proxy-core-resources-and-preconditions)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: Aurora read-only proxy endpoint](#phase-7-aurora-read-only-proxy-endpoint)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: Module outputs (consumer contract)](#phase-8-module-outputs-consumer-contract)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 9: Plan-only terraform test suite](#phase-9-plan-only-terraform-test-suite)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
  - [Phase 10: tests-localstack apply suite and FINDINGS](#phase-10-tests-localstack-apply-suite-and-findings)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
  - [Phase 11: MySQL engine fast-follow](#phase-11-mysql-engine-fast-follow)
    - [Tasks](#tasks-10)
    - [Success Criteria](#success-criteria-10)
  - [Phase 12: README, USAGE, CLAUDE.md, and docz closeout](#phase-12-readme-usage-claudemd-and-docz-closeout)
    - [Tasks](#tasks-11)
    - [Success Criteria](#success-criteria-11)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — Within-module file layout — RESOLVED (a)](#q1--within-module-file-layout--resolved-a)
  - [Q2 — Stubbing remote state in plan-only tests — RESOLVED (a)](#q2--stubbing-remote-state-in-plan-only-tests--resolved-a)
  - [Q3 — Proxy-to-DB composition and SG wiring — RESOLVED (remote state)](#q3--proxy-to-db-composition-and-sg-wiring--resolved-remote-state)
  - [Q4 — Proxy naming convention — RESOLVED (a)](#q4--proxy-naming-convention--resolved-a)
  - [Q5 — Scope of the subnet-id output addition — RESOLVED (a)](#q5--scope-of-the-subnet-id-output-addition--resolved-a)
  - [Q6 — MySQL phase: same IMPL vs separate follow-up — RESOLVED (a)](#q6--mysql-phase-same-impl-vs-separate-follow-up--resolved-a)
  - [Q7 — LocalStack Pro coverage — RESOLVED (flag-gated, off by default)](#q7--localstack-pro-coverage--resolved-flag-gated-off-by-default)
- [References](#references)
<!--toc:end-->

## Objective

Implement **`modules/rds/proxy`** — a standalone Terraform module placing an
Amazon RDS Proxy in front of any of the data-tier modules, composed via the
target's remote state (ADR-0001) and reusing its AWS-managed master secret.
Postgres ships first; MySQL follows as a phase in this same IMPL. The module is
dense with the plan-time validations the design calls for.

**Implements:**
[DESIGN-0010](../design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md)
(all eleven open questions resolved, option `a`), the deferred RDS Proxy
follow-up from
[DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md).

## Scope

### In Scope

- A new `modules/rds/proxy` Terraform module: scaffolding, variable surface
  with validations, remote-state composition, IAM role, security group, the
  RDS Proxy resource set, optional Aurora read-only endpoint, and outputs.
- A small output addition to the already-shipped `modules/rds/serverless`
  module (`db_subnet_ids`, `vpc_id`, the secret CMK arn, and the IAM-auth flag)
  so the proxy has a single upstream remote state (DESIGN-0010 Q11-a gap).
- Postgres (`postgres`, `aurora-postgresql`) first; MySQL (`mysql`,
  `aurora-mysql`) as Phase 11.
- Plan-only `terraform test` suite (the validation gate) + a Pro-gated
  `tests-localstack` apply suite.
- Module README, generated USAGE.md, CLAUDE.md inventory update, docz closeout.

### Out of Scope

- Implementing DESIGN-0007's deferred `instance` / `cluster` modules (the proxy
  targets the shipped `serverless` module first; instance/cluster are validated
  as they land per DESIGN-0007's rollout — DESIGN-0010 Q11-a).
- SQL Server / MariaDB engines, cross-VPC proxy endpoints, dedicated
  application-user secrets, end-to-end IAM-only auth (all DESIGN-0010
  Non-Goals / deferred hardening paths).
- Any Go code — this is a pure-Terraform module; the `/terraform` skill
  conventions apply, not the go-development plugin.

## Implementation Phases

Each phase builds on the previous one and is committed as its own conventional
commit. A phase is complete when all its tasks are checked off and its success
criteria are met. Gate commands are the `justfile` recipes
(`just tf <action> rds/proxy`).

**Composition is via remote state (IMPL Q3, ADR-0001).** The proxy reads its
target DB module's outputs — `master_user_secret_arn`, the DB
`security_group_id`, the secret CMK, subnet IDs, `vpc_id`, `engine`, and the
instance/cluster identifier — from a single `data.terraform_remote_state`
keyed on `var.target_type` + `var.target_identifier`. The proxy's own input
variables are just pointers (`region`, `name`, `target_type`,
`target_identifier`, `remote_state_bucket`) plus proxy-behaviour knobs
(TLS, timeouts, pool config, read-only endpoint, consumer SGs). This is the
same single-source-of-truth posture the read-replica module relies on, so
engine drift between the proxy and its target is impossible by construction.

---

### Phase 1: Module scaffolding, version pins, and variable surface

Establish the module directory, the standard scaffolding (copied verbatim per
the repo's per-module convention), and the full input contract with the
static, single-variable validations.

#### Tasks

- [x] Create `modules/rds/proxy/` with `versions.tf` (`hashicorp/aws ~> 6.2`,
      Terraform `>= 1.1`), `.terraform-docs.yml`, `.tflint.hcl`, and a
      `README.md` stub — copied verbatim from a sibling module.
- [x] Author `variables.tf` with the pointer + knob input surface (Q3 —
      composition by remote state, so the DB-derived values are *not* inputs).
      **Required**: `region`, `name` (proxy name, Q4-a), `target_type`,
      `target_identifier`, `remote_state_bucket` (the S3 bucket holding the
      target's state). **Optional knobs**: `db_port` (`null` → derive from the
      `engine` read from remote state), `allowed_consumer_sg_ids` (`[]`),
      `require_tls` (`true`), `require_iam_auth` (`false`),
      `idle_client_timeout` (`1800`), `create_read_only_endpoint` (`false`),
      `max_connections_percent` (`100`), `max_idle_connections_percent` (`50`),
      `connection_borrow_timeout` (`120`), `session_pinning_filters` (`[]`),
      `init_query` (`null`), `debug_logging` (`false`), `tags` (`{}`). Each
      variable carries `description` + `type` + `default` (optional only) +
      `nullable = false` where required.
- [x] Add the single-variable validations: V1 (`target_type ∈ {rds-instance,
      aurora-cluster, serverless}`), V6 (`max_connections_percent ∈ [1,100]`,
      `max_idle_connections_percent ∈ [0,100]`), V7
      (`connection_borrow_timeout >= 0`), each with a clear `error_message`.
- [x] Add a `main.tf` header comment block (module entrypoint).

#### Success Criteria

- `just tf validate rds/proxy` and `just tf fmt rds/proxy` pass.
- `just tf lint rds/proxy` reports no *real* defects. NB:
  `terraform_unused_declarations` fires for every variable and
  `terraform_unused_required_providers` for `aws` while the module is
  variables-only — these are intrinsic to a variables-first phase and clear
  once Phase 6 wires the `aws_db_proxy` resource set. Full lint-clean is
  re-verified at Phase 6 (and again at the Phase 12 final gate).
- Every variable has `description` + `type`; required variables are
  `nullable = false`.
- `just tf docs rds/proxy` renders the input table into `USAGE.md`.

---

### Phase 2: DB-module output prerequisite for proxy composition

Under remote-state composition (Q3) the proxy reads the DB module's outputs.
The shipped `serverless` module already emits `security_group_id`,
`master_user_secret_arn`, `kms_key_arn`, `engine`, `engine_version_actual`, the
cluster identifier, and `db_subnet_group_name` — close the remaining gaps so
the proxy has a single upstream (DESIGN-0010 Q11-a / Q5).

#### Tasks

- [x] Add `db_subnet_ids` (the private subnet IDs backing the subnet group) and
      `vpc_id` outputs to `modules/rds/serverless/outputs.tf`, sourced from the
      values already read in `network.tf` (the proxy needs raw subnet IDs for
      `vpc_subnet_ids` and the VPC id for SG placement).
- [x] Add a `master_user_secret_kms_key_arn` output (the CMK encrypting the
      managed master secret) so the proxy role can scope `kms:Decrypt` — or
      document that the default `aws/secretsmanager` key is used and the proxy
      policy handles it via a `kms:ViaService` condition. (The existing
      `kms_key_arn` output is the *storage* key, not necessarily the secret's.)
- [x] Add an `iam_database_authentication_enabled` output so the proxy's V4
      precondition can read the target's IAM-auth state from remote state.
- [x] Regenerate `modules/rds/serverless/USAGE.md` (`just tf docs rds/serverless`).
- [x] Add assertions for the new outputs to the serverless plan-only suite
      (extend `tests/default.tftest.hcl`).
- [x] Record in this doc's References (and flag for DESIGN-0007) that
      `instance` and `cluster` must emit the same outputs when they are built.

#### Success Criteria

- `modules/rds/serverless` outputs include `db_subnet_ids` + `vpc_id` (+ secret
  CMK arn + IAM-auth flag).
- `just tf all rds/serverless` passes (existing tests + new output assertions).
- `modules/rds/serverless/USAGE.md` is current.

---

### Phase 3: Remote-state composition and engine-family locals

Read the target's state and derive everything the proxy needs (Q3 — ADR-0001
remote-state composition). Engine, secret ARN, identifier, subnets, VPC, and
CMK all come from the single `data.terraform_remote_state.target`.

#### Tasks

- [x] `main.tf` (or `data.tf`): `data "terraform_remote_state" "target"`
      (`backend = "s3"`, `bucket = var.remote_state_bucket`,
      `key = "${var.region}/rds/${local.target_dir}/${var.target_identifier}/terraform.tfstate"`,
      `region = var.region`), with `local.target_dir` selected by
      `var.target_type` (`rds-instance → instance`, `aurora-cluster → cluster`,
      `serverless → serverless`).
- [x] `locals.tf`: alias the consumed outputs
      (`local.master_user_secret_arn`, `local.db_security_group_id`,
      `local.db_subnet_ids`, `local.vpc_id`, `local.secret_kms_key_arn`,
      `local.engine`, `local.iam_auth_enabled`) at the use site from
      `data.terraform_remote_state.target.outputs.*`.
- [x] `locals.tf`: static engine → `engine_family` map (Postgres rows first per
      Q9-a: `postgres`/`aurora-postgresql → POSTGRESQL`, port `5432`) keyed on
      `local.engine`; `local.port = coalesce(var.db_port, <map default>)`.
- [x] Route the target identifier: `local.db_instance_identifier` /
      `local.db_cluster_identifier` derived from `var.target_identifier` +
      `var.target_type` (exactly one is non-null on `aws_db_proxy_target`).

#### Success Criteria

- `just tf validate rds/proxy` passes.
- A plan with a Postgres target (remote state stubbed via `override_data`)
  resolves `engine_family = POSTGRESQL`, port `5432`, and the correct
  target-identifier routing. NB: locals are not directly observable in a plan —
  this resolution is asserted once Phase 6 wires `aws_db_proxy` (which sets
  `engine_family = local.engine_family`) and the Phase 9 tests assert on it.
  Verified concretely there.

---

### Phase 4: Proxy IAM role and secret-access policy

#### Tasks

- [x] `iam.tf`: `aws_iam_role.proxy` with a trust policy for
      `rds.amazonaws.com`.
- [x] An inline/managed policy granting `secretsmanager:GetSecretValue` on
      `local.master_user_secret_arn` and `kms:Decrypt` on
      `local.secret_kms_key_arn` (conditioned `kms:ViaService = secretsmanager.*`;
      when the CMK arn is absent, scope to the account's default
      `aws/secretsmanager` key) — all read from remote state.
- [x] Tag the role from `var.tags`.

#### Success Criteria

- `just tf validate/lint/fmt rds/proxy` pass.
- Plan shows the role + a least-privilege policy scoped to exactly the target's
  secret ARN and CMK (no wildcards).

---

### Phase 5: Proxy security group

#### Tasks

- [x] `security_group.tf`: `aws_security_group.proxy` in `local.vpc_id` (from
      remote state).
- [x] Ingress rules from each `var.allowed_consumer_sg_ids` on the engine
      listener port (`local.port`) — clients → proxy.
- [x] Egress rule to `local.db_security_group_id` on `local.port` — proxy → DB
      (Q3: the proxy SG egress targets the RDS cluster/instance SG + port; the
      SG id comes from the target's remote state).
- [x] Use `aws_vpc_security_group_ingress_rule` / `_egress_rule` with
      `referenced_security_group_id` (provider 6.x idiom), matching the
      `serverless` module's SG style.

#### Success Criteria

- `just tf validate/lint/fmt rds/proxy` pass.
- Plan: one ingress rule per consumer SG; an egress rule referencing the
  target's DB SG on the DB port.
- Reciprocal DB-side ingress is documented (operator passes
  `proxy_security_group_id` into the DB module's `allowed_consumer_sg_ids`).

---

### Phase 6: RDS Proxy core resources and preconditions

#### Tasks

- [x] `proxy.tf`: `aws_db_proxy.this` (`engine_family` from local, `role_arn`,
      `vpc_subnet_ids = local.db_subnet_ids`, `vpc_security_group_ids` =
      proxy SG, `require_tls`, `idle_client_timeout`, `debug_logging`, and an
      `auth` block: `auth_scheme = "SECRETS"`, `secret_arn =
      local.master_user_secret_arn`, `iam_auth = var.require_iam_auth ?
      "REQUIRED" : "DISABLED"`).
- [x] `aws_db_proxy_default_target_group.this` with `connection_pool_config`
      (`max_connections_percent`, `max_idle_connections_percent`,
      `connection_borrow_timeout`, `session_pinning_filters`, `init_query`).
- [x] `aws_db_proxy_target.this` setting `db_instance_identifier` (rds-instance)
      XOR `db_cluster_identifier` (aurora-cluster / serverless) by
      `var.target_type`.
- [x] `lifecycle.precondition`s: V2 (`local.engine` in a supported family), V4
      (`require_iam_auth` ⇒ `local.iam_auth_enabled` from remote state), V5
      (`local.master_user_secret_arn` is set, else IAM auth is configured).

#### Success Criteria

- `just tf validate/lint/fmt rds/proxy` pass.
- Plan against a Postgres serverless stub shows `aws_db_proxy` +
  `default_target_group` + `target` with `db_cluster_identifier` set and
  `db_instance_identifier` null.
- Precondition V4 fails the plan when `require_iam_auth = true` and the target
  lacks IAM auth (asserted in Phase 9).

---

### Phase 7: Aurora read-only proxy endpoint

#### Tasks

- [x] `aws_db_proxy_endpoint.read_only` with
      `count = var.create_read_only_endpoint && var.target_type != "rds-instance" ? 1 : 0`,
      `target_role = "READ_ONLY"`, `vpc_subnet_ids = local.db_subnet_ids`,
      `vpc_security_group_ids` = proxy SG.
- [x] Precondition V3 to fail loudly (not silently no-op) when
      `create_read_only_endpoint = true` is set on an `rds-instance` target.

#### Success Criteria

- `just tf validate/lint/fmt rds/proxy` pass.
- Plan: the endpoint exists iff `create_read_only_endpoint` and an Aurora
  target; V3 errors on `rds-instance` + `create_read_only_endpoint = true`.

---

### Phase 8: Module outputs (consumer contract)

#### Tasks

- [x] `outputs.tf`: `proxy_arn`, `proxy_name`, `proxy_endpoint` (writer),
      `read_only_endpoint` (the READ_ONLY endpoint or `null`),
      `proxy_security_group_id`, `proxy_role_arn`.
- [x] Descriptions documenting the contract — notably that
      `proxy_security_group_id` is passed into the DB module's
      `allowed_consumer_sg_ids` on a subsequent apply (Q3-a wiring).

#### Success Criteria

- `just tf validate/fmt rds/proxy` pass; `just tf docs rds/proxy` renders the
  outputs; `USAGE.md` is current.

---

### Phase 9: Plan-only terraform test suite

The primary gate, per [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md);
exercises all validations with no AWS. The `data.terraform_remote_state.target`
is stubbed via `override_data` (Q2-a), so each test supplies the target's
outputs directly without an S3 backend.

#### Tasks

- [x] `tests/default.tftest.hcl`: default shapes per `target_type` × engine
      (rds-instance/postgres, aurora-cluster/aurora-postgresql,
      serverless/aurora-postgresql) — `override_data` supplies the remote-state
      outputs; assert `engine_family` derivation, identifier selection
      (`db_instance_identifier` vs `db_cluster_identifier`), resource counts.
- [x] `tests/validation.tftest.hcl`: negatives V1–V7 — bad `target_type`,
      `require_iam_auth` against an IAM-disabled target (V4), `max_idle >
      max_connections` (V6), `create_read_only_endpoint` on `rds-instance`
      (V3), unsupported engine (V2).
- [x] `tests/read_only_endpoint.tftest.hcl`: endpoint present iff Aurora + flag.
- [x] `tests/connection_pool.tftest.hcl`: pool config plumbs through.
- [x] `tests/iam_auth.tftest.hcl`: `iam_auth` REQUIRED/DISABLED mapping.

#### Success Criteria

- `just tf test rds/proxy` passes (all plan-only cases, seconds, no LocalStack).
- Each validation negative errors with a clear, actionable message.
- `just tf all rds/proxy` is green.

---

### Phase 10: tests-localstack apply suite and FINDINGS

Per RFC-0001's gap-discovery pattern. RDS Proxy is LocalStack **Pro**-only, so
the apply suite is **flag-gated: off by default, on during build/test** (Q7).

#### Tasks

- [x] `tests-localstack/plan_smoke.tftest.hcl`: always-on, Community-safe
      plan-only smoke (remote state stubbed via `override_data`, no proxy
      apply). Offline-safe — a plan with overridden data makes no API calls.
- [x] `tests-localstack-pro/apply_pro.tftest.hcl`: the **Pro apply** suite (in
      its own directory so the default recipe never scans it). A `setup` `run`
      applies the minimal Aurora target fixture (`fixtures/db`) **and writes a
      stub state file to S3** at the proxy's key; `proxy_apply` +
      `proxy_read_only_endpoint` then apply `rds/proxy`, which reads that state
      for real via `data.terraform_remote_state.target`. **Correction:** the
      original sketch (bridge run outputs via `override_data`) does **not**
      parse — terraform test rejects `run.*` inside `override_*` values, so the
      S3 stub-state bridge (the serverless apply pattern) is used instead.
- [x] Add the enable-flag: a dedicated `_tf-test-localstack-pro` justfile recipe
      (`just tf test-localstack-pro rds/proxy`) for the `tests-localstack-pro/`
      dir. The default `just tf test-localstack rds/proxy` scans only
      `tests-localstack/` → runs only `plan_smoke`. Directory separation is the
      gate (terraform test has no per-run conditional skip).
- [x] `tests-localstack/FINDINGS.md`: document the Pro requirement (native RDS
      provider v4.4+, `CreateDBProxyEndpoint` v4.5+), the two-tier layout +
      recipe gate, the override_data limitation, and the Community fallback.
- [x] Probe both tiers; record outcomes in FINDINGS.md. **plan_smoke verified
      (offline).** apply_pro is `terraform validate`/parse/plan-valid but the
      live Pro apply is **not executed in this build environment** (no Pro
      container / `LOCALSTACK_AUTH_TOKEN` / Docker) — flagged in FINDINGS for a
      Pro run.

#### Success Criteria

- With the flag enabled on Pro: the apply suite provisions and asserts the full
  proxy resource set against a LocalStack target. **Pending — not executed in
  this build environment (no LocalStack Pro). The suite is authored and
  parse/plan-valid; live execution is flagged in FINDINGS.md.**
- With the flag off (default): only `plan_smoke` runs; Community stays green.
  **Verified** (`just tf test-localstack rds/proxy` → 1 passed, offline).
- FINDINGS.md documents the Pro requirement and the enable-flag. **Done.**

---

### Phase 11: MySQL engine fast-follow

Add the second engine (DESIGN-0010 Q9-a) — the resource graph is unchanged;
only `engine_family` / port differ.

#### Tasks

- [x] Add `mysql` / `aurora-mysql → MYSQL` (port `3306`) rows to the
      engine-family map in `locals.tf`.
- [x] Extend the V2 precondition / engine validation to accept the MySQL
      family.
- [x] Add plan-only cases: rds-instance/mysql and aurora-cluster/aurora-mysql
      (assert `engine_family = MYSQL`, port `3306`).
- [x] README multi-engine note.

#### Success Criteria

- `just tf test rds/proxy` includes passing MySQL cases for both target types.
- `just tf all rds/proxy` is green across Postgres and MySQL.

---

### Phase 12: README, USAGE, CLAUDE.md, and docz closeout

#### Tasks

- [x] Author `modules/rds/proxy/README.md`: overview + DESIGN-0010 link;
      quickstart (proxy in front of a `serverless` Postgres target);
      `target_type` usage; secret-reuse note; the SG-wiring instruction (pass
      `proxy_security_group_id` into the DB module's
      `allowed_consumer_sg_ids`); the **Serverless v2 cost caveat** (8-ACU
      billing floor + auto-pause blocked by an attached proxy); operational
      gotchas; tests; module map.
- [x] Regenerate `modules/rds/proxy/USAGE.md`.
- [x] Update `CLAUDE.md`: add `modules/rds/proxy` to the §Repository purpose
      `rds` inventory + a shape line; note the Pro-gated test divergence.
- [x] Mark IMPL-0010 `Completed` (frontmatter + body) and run `docz update`;
      move DESIGN-0010 to `Implemented`.
- [x] `just docs lint` clean for the new docs.

#### Success Criteria

- READMEs render; `USAGE.md` current; `CLAUDE.md` updated.
- `just docs lint` clean for IMPL-0010 + the module README.
- IMPL-0010 marked `Completed`; docz regenerates the README index.
- Final gate green: `just tf all rds/proxy`, `just tf all rds/serverless`,
  `just docs lint`.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/rds/proxy/versions.tf` | Create | `aws ~> 6.2`, terraform `>= 1.1` |
| `modules/rds/proxy/.terraform-docs.yml` | Create | per-module terraform-docs config (copied) |
| `modules/rds/proxy/.tflint.hcl` | Create | per-module tflint config (copied) |
| `modules/rds/proxy/variables.tf` | Create | pointer + knob input surface + validations V1/V6/V7 |
| `modules/rds/proxy/main.tf` | Create | entrypoint + `data.terraform_remote_state.target` (Q3) |
| `modules/rds/proxy/locals.tf` | Create | engine→family map, port + identifier routing, remote-state output aliases |
| `modules/rds/proxy/iam.tf` | Create | proxy IAM role + secret/KMS policy |
| `modules/rds/proxy/security_group.tf` | Create | proxy SG (ingress from consumers, egress to DB) |
| `modules/rds/proxy/proxy.tf` | Create | `aws_db_proxy` + target group + target + preconditions |
| `modules/rds/proxy/outputs.tf` | Create | consumer contract |
| `modules/rds/proxy/README.md` | Create | operator doc |
| `modules/rds/proxy/USAGE.md` | Create | terraform-docs generated |
| `modules/rds/proxy/tests/*.tftest.hcl` | Create | plan-only suite (validations) |
| `modules/rds/proxy/tests-localstack/*` | Create | `plan_smoke` (always-on, plan-only) + FINDINGS.md |
| `modules/rds/proxy/tests-localstack-pro/*` | Create | Pro apply suite (`apply_pro` + `fixtures/db`), off by default |
| `justfile` | Modify | add `_tf-test-localstack-pro` recipe (Q7 gate) |
| `modules/rds/serverless/outputs.tf` | Modify | add `db_subnet_ids` + `vpc_id` (+ secret CMK arn + IAM-auth flag) (Q11-a) |
| `modules/rds/serverless/USAGE.md` | Modify | regen |
| `modules/rds/serverless/tests/default.tftest.hcl` | Modify | assert new outputs |
| `CLAUDE.md` | Modify | add `modules/rds/proxy` inventory + shape |
| `docs/impl/README.md` | Modify | docz regen |
| `docs/design/0010-...md` | Modify | status → Implemented at closeout |

## Testing Plan

- [x] **Plan-only `terraform test` (`tests/`)** — the validation gate (Phase
      9): default shapes per target/engine, all V1–V7 negatives, read-only
      endpoint gating, pool config, IAM-auth mapping. The remote-state data
      source is stubbed via `override_data` (Q2-a). No AWS, runs in seconds.
- [x] **`tests-localstack` apply suite** — Pro-gated (Phase 10); Community
      falls back to `plan_smoke` with the gap recorded in `FINDINGS.md`.
- [x] **Serverless regression** — `just tf all rds/serverless` after the
      output addition (Phase 2).
- [ ] **Manual post-apply smoke (operator, not CI)** — connect through the
      proxy endpoint with the master secret; for Aurora, confirm the READ_ONLY
      endpoint routes to a reader. Documented in the README.

## Dependencies

- [DESIGN-0010](../design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md)
  — the source contract (all open questions resolved).
- `modules/rds/serverless` (IMPL-0007, shipped) — the first proxy target and
  the module gaining the `db_subnet_ids` / `vpc_id` / secret-CMK / IAM-auth
  outputs the proxy reads from remote state (Q3 — remote-state composition).
- DESIGN-0007's `instance` / `cluster` modules — future targets, not blocking
  (Q11-a: validate as they ship). **Output contract (Phase 2):** when built,
  each MUST emit the same proxy-composition outputs `serverless` now does —
  `db_subnet_ids`, `vpc_id`, `master_user_secret_arn`,
  `master_user_secret_kms_key_arn`, `security_group_id`, `engine`,
  `iam_database_authentication_enabled`, and the instance/cluster identifier —
  so a single `proxy` module fronts any `target_type`. Flagged for DESIGN-0007.
- `hashicorp/aws ~> 6.2` (fleet pin) — `aws_db_proxy` and friends are available.
- **LocalStack Pro** — required only for the Phase 10 apply suite.

## Open Questions

All seven questions resolved 2026-06-29 and folded into the phases above.
Q1/Q2/Q4/Q5/Q6 took option `a`; Q3 and Q7 took operator resolutions recorded
below.

### Q1 — Within-module file layout — RESOLVED (a)

**Resolved (a):** split by concern, mirroring `serverless` — `main.tf`
(entrypoint + the `terraform_remote_state` data source), `locals.tf`,
`variables.tf`, `iam.tf`, `security_group.tf`, `proxy.tf`, `outputs.tf`,
`versions.tf`. A single `main.tf` (b) was rejected as inconsistent with the
fleet.

### Q2 — Stubbing remote state in plan-only tests — RESOLVED (a)

**Resolved (a):** the plan-only tests stub `data.terraform_remote_state.target`
with `override_data` blocks, supplying the target's outputs (secret ARN, DB SG,
subnets, VPC, engine, identifier, IAM-auth flag) per case. No S3 backend, no
network — the validation gate runs in seconds. The alternative (a wrapper
fixture, b) was rejected as heavier than `override_data`.

### Q3 — Proxy-to-DB composition and SG wiring — RESOLVED (remote state)

**Resolved (operator):** the proxy composes via **remote state**, the fleet's
ADR-0001 convention — a single `data.terraform_remote_state.target` keyed on
`var.target_type` + `var.target_identifier` supplies `master_user_secret_arn`,
the DB `security_group_id`, subnet IDs, `vpc_id`, the secret CMK, `engine`, the
identifier, and the IAM-auth flag. The proxy's own inputs are just pointers
(`region`, `name`, `target_type`, `target_identifier`, `remote_state_bucket`)
and behaviour knobs. The proxy SG **egress targets the DB security group on the
DB port** (the SG id read from remote state); the DB SG's reciprocal ingress is
wired by passing `proxy_security_group_id` into the DB module's
`allowed_consumer_sg_ids`. This keeps the proxy aligned with DESIGN-0010 as
originally resolved (Q1-a / Q11-a) — no exception to ADR-0001. A variable-based
composition was considered and rejected: it would fork from the fleet's
single-source-of-truth pattern for no real gain.

### Q4 — Proxy naming convention — RESOLVED (a)

**Resolved (a):** explicit `var.name` for the proxy — operator-chosen, stable,
simplest surface. The `identifier_prefix` pattern (b) was rejected for v1.

### Q5 — Scope of the subnet-id output addition — RESOLVED (a)

**Resolved (a):** add `db_subnet_ids` + `vpc_id` (+ the secret CMK arn + the
IAM-auth flag) to `serverless` now (the only live target); record the output
contract that the unbuilt `instance` / `cluster` modules must satisfy when
built. Don't touch unbuilt modules (b rejected).

### Q6 — MySQL phase: same IMPL vs separate follow-up — RESOLVED (a)

**Resolved (a):** MySQL is Phase 11 of *this* IMPL (per DESIGN-0010 Q9-a),
committed after the Postgres phases are green. Not deferred to a separate
IMPL (b).

### Q7 — LocalStack Pro coverage — RESOLVED (flag-gated, off by default)

**Resolved (operator):** the Pro apply coverage **lives in the module** (not
dropped to plan-only), gated behind an **enable-flag that is off by default and
on during build/test**. Default `just tf test-localstack rds/proxy` runs only
the Community-safe `plan_smoke`; the Pro apply (`apply_pro.tftest.hcl`) runs
only when the flag is set (`LOCALSTACK_AUTH_TOKEN` present or a dedicated
`test-localstack-pro` recipe). Captured in Phase 10.

## References

- [DESIGN-0010](../design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md) — RDS Proxy module design (the contract this implements).
- [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS/Aurora module layout (the `instance`/`cluster`/`serverless` targets).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state` (the proxy↔target composition).
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants (the validation suite).
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy + gap-discovery pattern.
- [IMPL-0007](0007-aurora-serverless-v2-module-implementation.md) — Aurora Serverless v2 implementation (the structural analog + the module being extended in Phase 2).
- [Amazon RDS Proxy — User Guide](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html) and [`aws_db_proxy` resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_proxy).
