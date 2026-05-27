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
| `setup` | apply | n/a | VPC + 3 private subnets + S3 bucket with stub VPC state file |
| `apply_default` | apply | aurora-postgresql | Module-managed KMS + subnet group + SG + parameter groups + Serverless v2 cluster + db.serverless instance |
| `plan_mysql` | plan | aurora-mysql | MySQL endpoint resolution + plan-time validation + mysql parameter family lookup |

Run with `just tf test-localstack rds/serverless`. The recipe wires
`AWS_ENDPOINT_URL=http://localhost:4566` + fake credentials per the
sibling LocalStack-test pattern.

## Tier coverage

Per IMPL-0007 / DESIGN-0007 Q7 resolution: this suite is
**tier-agnostic by construction** — no test gates on LocalStack
Community vs Pro edition. The same `apply_localstack.tftest.hcl`
should pass identically on either tier.

- **Default tier**: LocalStack Community.
- **Verified tier**: LocalStack Pro 2026.5.0 (per the Q7
  implementation-time verification step).

If a differential gap surfaces (one tier 501s, the other doesn't),
document it here as a finding and file the sneakystack backlog item.

## Finding #1 — Aurora Serverless v2 surface coverage on LocalStack

**Status:** TBD pending first actual run.

**Risk surface:** Aurora Serverless v2 specifically (`engine_mode =
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

**Status:** TBD pending first actual run.

The module defaults to `manage_master_user_password = true` per
DESIGN-0007 Q2. AWS provisions a Secrets Manager secret holding the
master user password, encrypted with the same KMS key that encrypts
cluster storage (per IMPL-0007 Q12). LocalStack Pro 2026.5.0
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
