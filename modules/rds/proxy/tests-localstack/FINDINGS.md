<!-- markdownlint-disable-file MD025 MD041 MD013 -->
# tests-localstack: Findings

Gap-discovery write-ups for `modules/rds/proxy` per RFC-0001 +
DESIGN-0010 §Testing. RDS Proxy is a **LocalStack Pro-only** surface, so
this module splits its LocalStack coverage in two — unlike the
tier-agnostic serverless suite.

## Two-tier layout (IMPL-0010 Q7)

| Suite | Directory | Recipe | Default? | Needs |
|-------|-----------|--------|----------|-------|
| `plan_smoke` | `tests-localstack/` | `just tf test-localstack rds/proxy` | **on** | nothing (plan-only, offline-safe) |
| `apply_pro` | `tests-localstack-pro/` | `just tf test-localstack-pro rds/proxy` | **off** | LocalStack **Pro** on :4566 (`LOCALSTACK_AUTH_TOKEN`) |

The Pro apply is gated **off by default** by living in a separate
directory the default `test-localstack` recipe never scans — `terraform
test` has no per-run conditional skip, so directory separation is the
only clean gate. Operators opt in with the dedicated `test-localstack-pro`
recipe when building/testing against a Pro container (Q7: "off by default,
on when building and testing").

## Why Pro-only

RDS Proxy needs LocalStack's native RDS provider:

- `CreateDBProxy` / `CreateDBProxyTargetGroup` / `RegisterDBProxyTargets`
  — native RDS provider **v4.4+** (Pro).
- `CreateDBProxyEndpoint` (the Aurora READ_ONLY endpoint) — **v4.5+** (Pro).

LocalStack Community does not serve these, so the apply suite cannot run
there. The Community fallback is `plan_smoke` (plan-only).

## `plan_smoke` (always-on)

One plan-only run, remote state stubbed via `override_data` (Q2-a). It
asserts the proxy plans `engine_family = POSTGRESQL`, the serverless
target's `db_cluster_identifier`, and no read-only endpoint by default.
Because a plan with overridden data makes no API calls, it passes on
Community **and with no LocalStack at all**.

- **Verified:** `just tf test-localstack rds/proxy` → 1 passed (run in
  this build environment with no LocalStack container — confirms the
  offline-safe property).

## `apply_pro` (opt-in, Pro)

`fixtures/db` applies a minimal Aurora Serverless v2 target (VPC + subnets
+ SG + cluster with an AWS-managed master secret) **and writes a stub
remote-state file to S3** at the proxy's key
(`<region>/rds/serverless/<identifier>/terraform.tfstate`) with the seven
proxy-composition outputs. The proxy then applies and reads that state for
real via `data.terraform_remote_state.target`. Three runs: `setup`,
`proxy_apply`, `proxy_read_only_endpoint`.

### Finding — override_data cannot bridge run outputs

The IMPL-0010 Phase 10 sketch proposed bridging the fixture's outputs into
the proxy's remote-state data source via `override_data` referencing
`run.db.<output>`. **That does not parse** — terraform test rejects
`run.*` references inside `override_*` `values` ("Variables not allowed").
The working bridge is the **S3 stub-state** pattern the serverless apply
suite already uses: the fixture writes the outputs to an `aws_s3_object`
shaped as a tfstate `outputs` map, and the proxy reads it through the real
S3 backend (the recipe wires `AWS_ENDPOINT_URL`/key/secret/region). The
IMPL prose was corrected to match.

### Tier coverage / execution status

- **Authoring + static checks (this build environment):** fixture
  `terraform validate` ✓; whole-module `terraform fmt` ✓; `apply_pro`
  parses and plans — the only failure is `dial tcp :4566: connect:
  connection refused`, i.e. no container, **not** an HCL/validation error.
- **Live Pro apply: NOT YET EXECUTED.** This build environment has no
  LocalStack Pro container, no `LOCALSTACK_AUTH_TOKEN`, and no Docker, so
  `proxy_apply` / `proxy_read_only_endpoint` could not be run here. **To
  do:** run `just tf test-localstack-pro rds/proxy` against a LocalStack
  Pro 2026.x container and record the outcome below (including any
  501/NotImplemented gaps to file per RFC-0001). Until then the apply
  path is verified only structurally.

| Run | Command | Status |
|-----|---------|--------|
| `plan_smoke` (default suite) | plan | ✅ passed (offline) |
| `setup` | apply | ⏳ pending Pro container |
| `proxy_apply` | apply | ⏳ pending Pro container |
| `proxy_read_only_endpoint` | apply | ⏳ pending Pro container |
