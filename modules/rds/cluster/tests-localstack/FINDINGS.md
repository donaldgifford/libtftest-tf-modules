<!-- markdownlint-disable-file MD025 MD041 MD013 -->
# tests-localstack: Findings

Gap-discovery write-ups for `modules/rds/cluster` per RFC-0001 +
DESIGN-0013 §Testing. An Aurora **provisioned** cluster instance boots a
real embedded PostgreSQL, which LocalStack serves only in **Pro**, so
this module splits its LocalStack coverage in two — the same two-tier
layout `modules/rds/proxy` uses (IMPL-0012 Q5, resolved **b**), and
unlike the tier-agnostic `serverless` suite.

## Two-tier layout (IMPL-0012 Q5-b)

| Suite | Directory | Recipe | Default? | Needs |
|-------|-----------|--------|----------|-------|
| `plan_smoke` | `tests-localstack/` | `just tf test-localstack rds/cluster` | **on** | nothing (plan-only, offline-safe) |
| `apply_pro` | `tests-localstack-pro/` | `just tf test-localstack-pro rds/cluster` | **off** | LocalStack **Pro** on :4566 (`LOCALSTACK_AUTH_TOKEN`) |

The Pro apply is gated **off by default** by living in a separate
directory the default `test-localstack` recipe never scans — `terraform
test` has no per-run conditional skip, so directory separation is the
only clean gate. The `_tf-test-localstack-pro` recipe (added in
IMPL-0010) is module-argument-based, so it already picks up
`rds/cluster` now that the directory exists — no justfile change was
needed.

## Why Pro-only (for the apply)

Unlike Aurora Serverless v2 (where `instance_class = "db.serverless"`
provisions no real database engine, so the tier-agnostic `serverless`
suite applies cleanly on Community), an Aurora **provisioned** cluster
instance has a concrete `instance_class` (e.g. `db.t3.medium`,
`db.r6g.large`). LocalStack Pro boots a **real embedded PostgreSQL** per
cluster instance to back it; Community's mock RDS does not. So the full
apply is Pro-gated, and the Community fallback is `plan_smoke`
(plan-only).

## `plan_smoke` (always-on)

One plan-only run, VPC remote state stubbed via `override_data`. It
asserts the cluster plans `engine_mode = "provisioned"`, plans **no**
`serverlessv2_scaling_configuration` block (the provisioned distinction),
and that the writer plans a real `instance_class` (`var.instance_class`),
never `db.serverless`. Because a plan with overridden data makes no API
calls, it passes on Community **and with no LocalStack at all**.

- **Verified:** `just tf test-localstack rds/cluster` → **1 passed** (run
  in this build environment with no LocalStack container — confirms the
  offline-safe property).

## `apply_pro` (opt-in, Pro)

`fixtures/setup` builds a VPC + 3 private subnets (Aurora needs ≥2 AZs
for the DB subnet group) **and writes a stub VPC state file to S3** at the
module's key (`<region>/vpc/<vpc_name>/terraform.tfstate`). The cluster
then applies and reads that state for real via
`data.terraform_remote_state.vpc` — the same S3-stub bridge the
`serverless` + `proxy` apply suites use. Three runs: `setup` (apply),
`apply_default` (apply, `aurora-postgresql`, `engine_version` pinned to
16), `plan_mysql` (plan-only, `aurora-mysql`).

### Finding — override_data cannot bridge run outputs

As documented in the `proxy` FINDINGS: `terraform test` rejects `run.*`
references inside `override_*` `values` ("Variables not allowed"). The
working bridge is the **S3 stub-state** pattern — the fixture writes the
VPC outputs to an `aws_s3_object` shaped as a tfstate `outputs` map, and
the module reads it through the real S3 backend (the recipe wires
`AWS_ENDPOINT_URL`/key/secret/region).

### Finding — engine_version pinned to 16 for the apply

The module default resolves to Aurora PostgreSQL major **18** (PG 18
GA'd 2026-06-11), which is newer than the LocalStack Pro 2026.6.0 image's
engine catalog. `apply_default` pins `engine_version = "16"` (the version
verified for the `serverless` apply). Bump this pin once a LocalStack
image serving Aurora PG 18 ships.

### Finding — RDS apply needs a Docker named volume, NOT a macOS bind mount

This is the **same macOS gotcha the `serverless` + `proxy` Pro applies
hit** — it applies to any RDS-backed apply on LocalStack Pro:

```text
FATAL: data directory ".../rds/postgres/.../<cluster>/data" has wrong ownership
HINT:  The server must be started by the user that owns the data directory.
```

LocalStack Pro boots a real embedded PostgreSQL for each cluster and
drops to a non-root user to run it. When `/var/lib/localstack` is a
**macOS host bind mount** (the `lstk` default), Docker Desktop's
file-sharing layer ignores in-container `chown`, so the RDS data dir
stays `root`-owned and `initdb`'s ownership check fails.

**Fix:** back `/var/lib/localstack` with a **Docker named volume** (lives
in Docker's Linux VM, where `chown` sticks). `lstk` only supports
host-dir bind mounts, so run LocalStack Pro directly:

```bash
docker volume create ls-data
docker run -d --name localstack-pro -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN="$LOCALSTACK_AUTH_TOKEN" \
  -v ls-data:/var/lib/localstack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  localstack/localstack-pro:latest
```

(A Linux host bind mount is unaffected — this is macOS/Docker-Desktop
specific.) See the `serverless` and `proxy` FINDINGS for the same finding.

**Confirmed for this module.** `lstk` (v0.7.1) brings up Pro fine and
activates the license, but mounts `/var/lib/localstack` from
`~/Library/Caches/lstk/volume/localstack-aws` — a host **bind mount**,
with no named-volume option (`lstk volume` only manages a host dir). So
the live apply here was run against LocalStack Pro launched **directly**
via `docker run` with `-v ls-cluster-data:/var/lib/localstack` (a Docker
named volume) and the same `LOCALSTACK_AUTH_TOKEN` `lstk` uses — the
provisioned cluster's `initdb` then succeeded and all three runs passed.

### Tier coverage / execution status

- **Authoring + static checks:** `fixtures/setup` `terraform validate` ✓;
  whole-module `terraform fmt` ✓; `apply_pro` parses + inits under
  `-test-directory=tests-localstack-pro` ✓.
- **`plan_smoke`: EXECUTED AND PASSING** (offline, 1/1) — see above.
- **Live Pro apply: EXECUTED AND PASSING.** Run against LocalStack Pro
  **2026.6.2** (`edition: pro`, license activated) backed by a Docker
  **named volume** per the finding above — `just tf test-localstack-pro
  rds/cluster` → **3 passed, 0 failed**. No 501/NotImplemented gaps
  surfaced; the native RDS provider booted the embedded PostgreSQL for the
  provisioned writer, provisioned the module-managed KMS key + alias, the
  subnet group, both parameter groups, and the `db.t3.medium` writer
  (`tftest-rds-1`). `engine_version` pinned to 16 (the module default
  resolves to PG 18, newer than the image's catalog).

| Run | Command | Status |
|-----|---------|--------|
| `plan_smoke` (default suite) | plan | ✅ passed (offline) |
| `setup` | apply | ✅ passed (Pro 2026.6.2, named volume) |
| `apply_default` | apply | ✅ passed (Pro 2026.6.2, named volume) |
| `plan_mysql` | plan | ✅ passed (Pro 2026.6.2, named volume) |
