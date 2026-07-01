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

`fixtures/db` applies a minimal Aurora Serverless v2 target (a VPC, two
subnets, an SG, and a cluster with an AWS-managed master secret) **and
writes a stub remote-state file to S3** at the proxy's key
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

### Finding — RDS apply needs a Docker named volume, NOT a macOS bind mount

`apply_pro` was blocked on the first live attempt by a LocalStack-side
error, **not** a module/test defect:

```text
FATAL: data directory ".../rds/postgres/.../<cluster>/data" has wrong ownership
HINT:  The server must be started by the user that owns the data directory.
initdb: removing contents of data directory ...
```

LocalStack Pro boots a **real embedded PostgreSQL** for each Aurora
cluster and drops to a non-root user to run it (Postgres refuses to run as
root). When `/var/lib/localstack` is a **macOS host bind mount** (the
default for `lstk`, which mounts `~/Library/Caches/lstk/volume/...`),
Docker Desktop's file-sharing layer ignores in-container `chown`, so the
RDS data dir stays `root`-owned and `initdb`'s ownership check fails — the
cluster never reaches `available` and the proxy runs are skipped.

**Fix:** back `/var/lib/localstack` with a **Docker named volume** (lives
in Docker's Linux VM, where `chown` sticks) instead of a host bind mount.
`lstk` only supports host-dir bind mounts, so RDS-backed apply tests must
run against LocalStack launched directly, e.g.:

```bash
docker volume create ls-data
docker run -d --name localstack-pro -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN="$LOCALSTACK_AUTH_TOKEN" \
  -v ls-data:/var/lib/localstack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  localstack/localstack-pro:latest
```

(A Linux host bind mount is unaffected — this is macOS/Docker-Desktop
specific.) The endpoints in `apply_pro.tftest.hcl` themselves are correct;
`localhost:4566` and `localhost.localstack.cloud:4566` both resolve to
127.0.0.1, so no endpoint change was required.

### Tier coverage / execution status

- **Authoring + static checks:** fixture `terraform validate` ✓;
  whole-module `terraform fmt` ✓; `apply_pro` parses and plans.
- **Live Pro apply: EXECUTED AND PASSING.** Run against LocalStack Pro
  2026.6.0 (`edition: pro`, license activated) backed by a Docker **named
  volume** per the finding above — `just tf test-localstack-pro rds/proxy`
  → **3 passed, 0 failed**. No 501/NotImplemented gaps surfaced; the
  native RDS provider served `CreateDBProxy*` and `CreateDBProxyEndpoint`.

| Run | Command | Status |
|-----|---------|--------|
| `plan_smoke` (default suite) | plan | ✅ passed (offline) |
| `setup` | apply | ✅ passed (Pro, named volume) |
| `proxy_apply` | apply | ✅ passed (Pro, named volume) |
| `proxy_read_only_endpoint` | apply | ✅ passed (Pro, named volume) |
