<!-- markdownlint-disable-file MD025 MD041 MD013 -->
# tests-localstack: Findings

Gap-discovery write-ups for `modules/rds/serverless` per RFC-0001 +
DESIGN-0007 §Testing Strategy.

This document captures what LocalStack actually serves for the
module's Aurora Serverless v2 surface, the gaps that surface during
`terraform test` runs against LocalStack, and any 501/NotImplemented
errors that warrant a sneakystack ticket per RFC-0001.

## Test runs

The `apply_localstack.tftest.hcl` suite has three runs (per IMPL-0007
Q5):

| Run | Command | Engine | Coverage |
|-----|---------|--------|----------|
| `setup` | apply | n/a | Shared `test/fixtures/reference-vpc` — three-tier `Network`-tagged topology + S3 bucket seeding the full nine-output vpc-lookup state (IMPL-0014) |
| `apply_default` | apply | aurora-postgresql | Module-managed KMS + subnet group + SG + parameter groups + Serverless v2 cluster + db.serverless instance |
| `plan_mysql` | plan | aurora-mysql | MySQL endpoint resolution + plan-time validation + mysql parameter family lookup |

Run with `just tf test-localstack rds/serverless`. The recipe wires
`AWS_ENDPOINT_URL=http://localhost:4566` + fake credentials per the
sibling LocalStack-test pattern.

> **Engine-version pin (2026-07).** The module's default Aurora PostgreSQL
> major was bumped `16 → 18` (Aurora PG 18 GA'd 2026-06-11, per DESIGN-0012
> Q8). The `apply_default` run explicitly pins `engine_version = "16"` because
> major 18 is newer than this LocalStack image's engine catalog — the Pro
> apply stays verified against a known-good version. Bump the pin once a
> LocalStack image serving Aurora PG 18 lands.

## Tier coverage

Per IMPL-0007 / DESIGN-0007 Q7 resolution: this suite is
**tier-agnostic by construction** — no test gates on LocalStack
Community vs Pro edition. The same `apply_localstack.tftest.hcl`
should pass identically on either tier.

- **Default tier**: LocalStack Community.
- **Verified tier**: LocalStack **Pro 2026.6.0** — first live run on
  2026-07-01, **3 passed, 0 failed** (`setup` + `apply_default` +
  `plan_mysql`). Supersedes the earlier implementation-time claim against
  2026.5.0, which was never actually executed.

> **macOS caveat.** Because `apply_default` boots a real embedded Postgres
> for the Aurora cluster, `/var/lib/localstack` must be a Docker **named
> volume**, not a macOS host bind mount (the `lstk` default) — else
> `initdb` fails on data-dir ownership. Same finding as
> `modules/rds/proxy/tests-localstack/FINDINGS.md`.

If a differential gap surfaces (one tier 501s, the other doesn't),
document it here as a finding and file the sneakystack backlog item.

## Finding #1 — Aurora Serverless v2 surface coverage on LocalStack

**Status:** ✅ Verified on Pro 2026.6.0 (2026-07-01). `apply_default`
provisions the full Serverless v2 stack — module-managed KMS, subnet group,
SG, DB + cluster parameter groups, the `aws_rds_cluster` (`engine_mode =
"provisioned"` + `serverlessv2_scaling_configuration`), and the
`db.serverless` `aws_rds_cluster_instance` — with **no 501/NotImplemented**.
The high-risk Serverless v2 scaling config + `db.serverless` instance class
are served by LocalStack Pro's native RDS provider. No sneakystack ticket
needed.

**Risk surface (retained for context):** Aurora Serverless v2 specifically
(`engine_mode =
"provisioned"` + `serverlessv2_scaling_configuration` +
`instance_class = "db.serverless"`) is the highest-risk piece of
this module's AWS API surface for LocalStack coverage. Baseline RDS
(`aws_db_subnet_group`, `aws_security_group`, `aws_db_parameter_group`,
`aws_rds_cluster_parameter_group`, `aws_rds_cluster`,
`aws_rds_cluster_instance`) is broadly supported on Community; the
Serverless v2 scaling configuration + db.serverless instance class
require explicit LocalStack support.

**Action if `apply_default` 501s:** follow the IMPL-0005 Phase 9
fall-back pattern documented in
`modules/ecr/pull-through-cache/tests-localstack/FINDINGS.md`:

1. Comment out the `apply_default` run body, preserving it as
   commented HCL for re-enable when LocalStack lands the missing
   API.
2. Replace with a `plan_smoke` run that proves provider endpoint
   resolution + plan-time validation against LocalStack.
3. Update this finding with the exact 501 error string + the API
   name.
4. File a sneakystack backlog ticket.

## Finding #2 — Secrets Manager integration for `manage_master_user_password = true`

**Status:** ✅ Verified on Pro 2026.6.0 (2026-07-01). `apply_default` runs
with the default `manage_master_user_password = true` and the managed-secret
path succeeds — the cluster's `master_user_secret` is populated (the RDS
Proxy Pro suite consumes exactly this secret ARN cross-module, so the path
is doubly exercised).

The module defaults to `manage_master_user_password = true` per
DESIGN-0007 Q2. AWS provisions a Secrets Manager secret holding the
master user password, encrypted with the same KMS key that encrypts
cluster storage (per IMPL-0007 Q12). LocalStack Pro 2026.6.0
supports Secrets Manager broadly; LocalStack Community has partial
support.

If `apply_default` fails on the Secrets-Manager-managed-password path
specifically, two fallbacks are available:

- **Tier-specific:** flip the test to `manage_master_user_password =
  false` + `master_password = "tftest-localstack-only"` for the
  apply run. Documents a coverage gap, doesn't block the suite.
- **Tier-agnostic:** skip the apply, fall back to `plan_smoke`
  per Finding #1.

## Out-of-scope (libtftest / sneakystack backlog)

Per RFC-0001 §Phase 3 — apply-time runtime validation requires
libtftest or sneakystack:

- `pg_isready` / `mysqladmin ping` through the cluster's writer
  endpoint after apply.
- AWS-managed master password rotation event surfacing in Secrets
  Manager.
- IAM database authentication token generation (`aws rds
  generate-db-auth-token`) and SQL-level connect.
- Aurora Serverless v2 auto-scale events (ACU bumps under load).
- `final_snapshot_identifier` actually being captured on destroy
  (requires destroy then describe-db-cluster-snapshots).
