<!-- markdownlint-disable-file MD025 MD041 MD013 -->
# tests-localstack: Findings

Gap-discovery write-ups for `modules/rds/instance` per RFC-0001 +
DESIGN-0012 §Testing. A plain `aws_db_instance` is baseline RDS
(feature-supported on both tiers), but on LocalStack **Pro** the instance
boots a **real embedded PostgreSQL**, and there is **no token-free
Community LocalStack** in the 2026.6.x line (the unified image exits 55
without a `LOCALSTACK_AUTH_TOKEN`). So this module splits its LocalStack
coverage in two — the same two-tier layout `modules/rds/cluster` /
`modules/rds/proxy` use (IMPL-0011 Q5, re-resolved **b**), rather than the
single tier-agnostic suite the original Q5=a assumed.

## Two-tier layout (IMPL-0011 Q5-b)

| Suite | Directory | Recipe | Default? | Needs |
|-------|-----------|--------|----------|-------|
| `plan_smoke` | `tests-localstack/` | `just tf test-localstack rds/instance` | **on** | nothing (plan-only, offline-safe) |
| `apply_pro` | `tests-localstack-pro/` | `just tf test-localstack-pro rds/instance` | **off** | LocalStack **Pro** on :4566 (`LOCALSTACK_AUTH_TOKEN`) |

The Pro apply is gated **off by default** by living in a separate
directory the default `test-localstack` recipe never scans — `terraform
test` has no per-run conditional skip, so directory separation is the only
clean gate. The `_tf-test-localstack-pro` recipe (added in IMPL-0010) is
module-argument-based, so it already picks up `rds/instance` now that the
directory exists — no justfile change was needed.

## Why the apply is Pro-gated (and Q5 flipped a → b)

The original IMPL-0011 Q5=a assumed a single Community-default apply
suite, reasoning "`aws_db_instance` is baseline RDS, broadly supported."
That premise no longer holds after 0012/0013:

1. **No token-free Community image.** Verified 2026-07-11 against
   `localstack/localstack:stable` (2026.6.2) and `:latest`: the unified
   image **exits 55 — "License activation failed! No credentials were
   found"** without a token. The only LocalStack you can boot is the Pro
   one (via the `lstk` token).
2. **The apply boots a real engine on Pro.** LocalStack Pro spins up an
   embedded PostgreSQL for a plain `aws_db_instance` (not a mock), so a
   real apply hits the macOS named-volume `initdb` caveat below — exactly
   like the Aurora siblings. A plan boots no engine, so `plan_smoke` stays
   tier-agnostic.

## `plan_smoke` (always-on)

Two plan-only runs (`plan_smoke` postgres + `plan_mysql`), VPC remote
state stubbed via `override_data`. Asserts the instance plans `engine =
postgres`, `storage_encrypted = true`, the concrete `var.instance_class`,
`storage_type = gp3`, and the resolved parameter family (`postgres18` /
`mysql8.4`). Because a plan with overridden data makes no API calls, it
passes on Community **and with no LocalStack at all**.

- **Verified:** `just tf test-localstack rds/instance` → **2 passed**
  (run offline in this build environment with no LocalStack container —
  confirms the offline-safe property).

## `apply_pro` (opt-in, Pro)

`fixtures/setup` builds a VPC + 3 private subnets (the DB subnet group
needs ≥2 AZs) **and writes a stub VPC state file to S3** at the module's
key (`<region>/vpc/<vpc_name>/terraform.tfstate`). The instance then
applies and reads that state for real via
`data.terraform_remote_state.vpc` — the same S3-stub bridge the
`serverless` + `cluster` apply suites use. Three runs: `setup` (apply),
`apply_default` (apply, `postgres`, `engine_version` pinned to 16),
`plan_mysql` (plan-only, `mysql`).

### Finding — deletion_protection must be disabled for the test teardown

The module defaults `deletion_protection = true` (correct for prod). On
the FIRST Pro run, all three runs passed but `terraform test`'s automatic
teardown then failed:

```text
Error: deleting RDS DB Instance (tftest-rds): api error
InvalidParameterCombination: Cannot delete protected DB Instance, please
disable deletion protection and try again.
```

Unlike the Aurora **cluster** apply (where LocalStack does not enforce
protection on the cluster the same way — that suite's teardown passed with
the default), LocalStack Pro enforces `deletion_protection` on a
standalone `aws_db_instance` at `DeleteDBInstance`. `apply_pro` therefore
sets `deletion_protection = false` **and** `skip_final_snapshot = true` in
its shared `variables` so the ephemeral test instance is destroyable. The
module default stays `true`.

### Finding — override_data cannot bridge run outputs

As documented in the `proxy` / `cluster` FINDINGS: `terraform test`
rejects `run.*` references inside `override_*` `values` ("Variables not
allowed"). The working bridge is the **S3 stub-state** pattern — the
fixture writes the VPC outputs to an `aws_s3_object` shaped as a tfstate
`outputs` map, and the module reads it through the real S3 backend (the
recipe wires `AWS_ENDPOINT_URL`/key/secret/region).

### Finding — engine_version pinned to 16 for the apply

The module default resolves to PostgreSQL major **18** (PG 18 GA'd 2026),
which is newer than the LocalStack Pro 2026.6.2 image's engine catalog.
`apply_default` pins `engine_version = "16"` (the version verified for the
`serverless` / `cluster` applies). Bump this pin once a LocalStack image
serving PG 18 ships.

### Finding — Q3 storage-autoscaling drift (no ignore_changes)

Q3=a: rely on the AWS provider's built-in `allocated_storage` diff
suppression when `max_allocated_storage` is set, adding **no**
`lifecycle.ignore_changes` (which would also suppress deliberate operator
resizes). The plan-only `storage_autoscaling.tftest.hcl` confirms the
config plans cleanly with the ceiling set (`allocated_storage` stays the
configured floor, `max_allocated_storage` passes through) and that a
ceiling < floor trips the precondition. The full autoscale→replan
drift-suppression confirmation requires driving real autoscaling growth
(a longer-running Pro exercise not run here); the design decision +
provider behaviour are documented in `instance.tf`. No drift was observed
in the Pro `apply_default` run (which set no `max_allocated_storage`).

### Finding — RDS apply needs a Docker named volume, NOT a macOS bind mount

This is the **same macOS gotcha the `serverless` / `cluster` / `proxy`
Pro applies hit** — it applies to any RDS-backed apply on LocalStack Pro:

```text
FATAL: data directory ".../rds/postgres/.../<instance>/data" has wrong ownership
HINT:  The server must be started by the user that owns the data directory.
```

LocalStack Pro boots a real embedded PostgreSQL and drops to a non-root
user to run it. When `/var/lib/localstack` is a **macOS host bind mount**
(the `lstk` default), Docker Desktop's file-sharing layer ignores
in-container `chown`, so the RDS data dir stays `root`-owned and
`initdb`'s ownership check fails.

**Fix:** back `/var/lib/localstack` with a **Docker named volume** (lives
in Docker's Linux VM, where `chown` sticks). `lstk` only supports
host-dir bind mounts, so run LocalStack Pro directly:

```bash
docker volume create ls-instance-data
docker run -d --name localstack-pro -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN="$LOCALSTACK_AUTH_TOKEN" \
  -v ls-instance-data:/var/lib/localstack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  localstack/localstack-pro:latest
```

(A Linux host bind mount is unaffected — this is macOS/Docker-Desktop
specific.) The `lstk`-injected `LOCALSTACK_AUTH_TOKEN` is the working
len-39 `ls-` token (extract via `docker exec <lstk-cid> printenv
LOCALSTACK_AUTH_TOKEN`); the len-70 keychain login token fails direct
activation. See the `serverless` / `cluster` / `proxy` FINDINGS for the
same finding.

### Tier coverage / execution status

- **Authoring + static checks:** `fixtures/setup` `terraform validate` ✓;
  whole-module `terraform fmt` ✓; `apply_pro` parses + inits under
  `-test-directory=tests-localstack-pro` ✓.
- **`plan_smoke`: EXECUTED AND PASSING** (offline, 2/2) — see above.
- **Live Pro apply: EXECUTED AND PASSING.** Run against LocalStack Pro
  **2026.6.2** (`edition: pro`, license activated) backed by a Docker
  **named volume** per the finding above — `just tf test-localstack-pro
  rds/instance` → **3 passed, 0 failed** (with clean teardown). No
  501/NotImplemented gaps surfaced; the native RDS provider booted the
  embedded PostgreSQL for the `db.t3.micro` instance (`tftest-rds`),
  provisioned the module-managed KMS key + alias, the subnet group, the
  parameter group, and the AWS-managed master user secret.
  `engine_version` pinned to 16 (the module default resolves to PG 18,
  newer than the image's catalog).

| Run | Command | Status |
|-----|---------|--------|
| `plan_smoke` (default suite) | plan | ✅ passed (offline) |
| `plan_mysql` (default suite) | plan | ✅ passed (offline) |
| `setup` | apply | ✅ passed (Pro 2026.6.2, named volume) |
| `apply_default` | apply | ✅ passed (Pro 2026.6.2, named volume) |
| `plan_mysql` (pro suite) | plan | ✅ passed (Pro 2026.6.2, named volume) |
