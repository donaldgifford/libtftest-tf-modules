<!-- markdownlint-disable-file MD025 MD041 MD013 -->
# tests-localstack: Findings

Gap-discovery write-ups for `modules/rds/read-replica` per RFC-0001 +
DESIGN-0014 §Testing. Reader instances are Aurora (a real embedded
PostgreSQL) **and** the apply must bridge the cluster's remote state
through a real S3-object fixture, so this module splits its LocalStack
coverage in two — the same two-tier layout `modules/rds/proxy` uses
(IMPL-0013 Q3).

## Two-tier layout (IMPL-0013 Q3)

| Suite | Directory | Recipe | Default? | Needs |
|-------|-----------|--------|----------|-------|
| `plan_smoke` | `tests-localstack/` | `just tf test-localstack rds/read-replica` | **on** | nothing (plan-only, offline-safe) |
| `apply_pro` | `tests-localstack-pro/` | `just tf test-localstack-pro rds/read-replica` | **off** | LocalStack **Pro** on :4566 (`LOCALSTACK_AUTH_TOKEN`) |

The Pro apply is gated **off by default** by living in a separate
directory the default `test-localstack` recipe never scans. The
`_tf-test-localstack-pro` recipe (added in IMPL-0010) is
module-argument-based, so it already picks up `rds/read-replica` now that
the directory exists — no justfile change was needed.

## Why Pro-only (for the apply)

Two Pro-tier requirements stack:

1. **Aurora reader instances** boot a real embedded PostgreSQL — Community
   does not serve them (same reason as `cluster`/`serverless`).
2. **Cross-state bridge.** The reader reads the cluster's outputs via
   `data.terraform_remote_state.rds_cluster`. `override_data` cannot
   reference a prior apply's outputs, so the apply needs the cluster's
   state materialised in S3 — a real S3 round-trip that only makes sense
   under LocalStack.

The Community fallback is `plan_smoke` (plan-only, cluster state stubbed
via `override_data`).

## `plan_smoke` (always-on)

One plan-only run, cluster remote state stubbed via `override_data`. It
asserts the readers plan one instance named `<identifier_prefix>-replica-
<key>`, attached to the stubbed `cluster_identifier`, with engine
inherited from the stubbed cluster outputs. Because a plan with
overridden data makes no API calls, it passes on Community **and with no
LocalStack at all**.

- **Verified:** `just tf test-localstack rds/read-replica` → **1 passed**
  (run in this build environment with no LocalStack container — confirms
  the offline-safe property).

## `apply_pro` (opt-in, Pro)

Per **Q4-b**, `fixtures/cluster` instantiates the **actual
`modules/rds/cluster` module** (via a relative `source = "../../../../
cluster"`) — highest fidelity, and the reader-consumed output shape is
exactly what the cluster emits (no hand-maintained stub to drift). Two
runs: `setup` (apply the fixture) → `apply_replicas` (attach the readers,
assert count / identifiers / per-reader endpoints).

### Finding — three-level state dependency needs a deferred module read

The cluster module itself reads a VPC remote state, so the fixture has a
**three-level** state chain: VPC state → cluster state → readers. The VPC
now comes from the shared `test/fixtures/reference-vpc` module (IMPL-0014
Phase 3), which seeds the nine-output VPC state. In a single `terraform
apply`, the cluster module's `data.terraform_remote_state.vpc` would read
at *plan* time, before that VPC state S3 object exists. The fix: give the
`module "cluster"` block a `depends_on = [module.vpc]`, which **defers the
module's data-source reads to apply** — after the shared VPC fixture (and
its seeded state object) is written. The fixture then writes the cluster
module's outputs to S3 (into the shared fixture's bucket,
`module.vpc.bucket_name`) as the stub cluster state at the read-replica's
key
(`<region>/rds/cluster/<cluster_identifier>/terraform.tfstate`), and
`apply_replicas` reads it for real. (The `proxy` fixture avoided this by
hand-rolling its cluster, so it had no nested remote state; Q4-b's
real-module choice is what introduces — and the `depends_on` resolves —
the extra level.)

### Finding — override_data cannot bridge run outputs

As documented in the `proxy` + `cluster` FINDINGS: `terraform test`
rejects `run.*` references inside `override_*` `values`. The working
bridge is the **S3 stub-state** pattern — the fixture writes the outputs
to an `aws_s3_object` shaped as a tfstate `outputs` map, and the module
reads it through the real S3 backend (the recipe wires
`AWS_ENDPOINT_URL`/key/secret/region).

### Finding — RDS apply needs a Docker named volume, NOT a macOS bind mount

Because the fixture applies the real cluster module (embedded PostgreSQL
writer) plus Aurora readers, the **same macOS gotcha** the
`serverless`/`cluster`/`proxy` Pro applies hit applies here:

```text
FATAL: data directory ".../rds/postgres/.../<cluster>/data" has wrong ownership
```

`lstk` (v0.7.1) activates Pro fine but mounts `/var/lib/localstack` from a
host **bind mount** (`~/Library/Caches/lstk/volume/...`), where Docker
Desktop's file-sharing ignores in-container `chown`, so `initdb` fails.
**Fix:** back `/var/lib/localstack` with a Docker **named volume**. `lstk`
only supports host-dir bind mounts, so the live apply here was run against
LocalStack Pro launched **directly**:

```bash
docker volume create ls-rr-data
docker run -d --name localstack-pro-rr -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN="$LOCALSTACK_AUTH_TOKEN" \
  -v ls-rr-data:/var/lib/localstack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  localstack/localstack-pro:latest
```

(the `LOCALSTACK_AUTH_TOKEN` is the `ls-` token `lstk` exchanges its login
for — read it from the running `lstk` container's env). A Linux host bind
mount is unaffected — this is macOS/Docker-Desktop specific. See the
`serverless`, `cluster`, and `proxy` FINDINGS for the same finding.

### Tier coverage / execution status

- **Authoring + static checks:** `fixtures/cluster` `terraform validate`
  ✓ (instantiates the real cluster module); whole-module `terraform fmt`
  ✓; `apply_pro` parses + inits under `-test-directory=tests-localstack-
  pro` ✓.
- **`plan_smoke`: EXECUTED AND PASSING** (offline, 1/1).
- **Live Pro apply: EXECUTED AND PASSING.** Run against LocalStack Pro
  **2026.6.2** (`edition: pro`, license activated) backed by a Docker
  **named volume** — `just tf test-localstack-pro rds/read-replica` →
  **2 passed, 0 failed**. The real cluster module applied end-to-end
  (KMS, subnet group, parameter groups, cluster, writer), its outputs
  bridged through S3, and two readers attached with populated endpoints.
  No 501/NotImplemented gaps surfaced.

| Run | Command | Status |
|-----|---------|--------|
| `plan_smoke` (default suite) | plan | ✅ passed (offline) |
| `setup` (real cluster module + S3 bridge) | apply | ✅ passed (Pro 2026.6.2, named volume) |
| `apply_replicas` | apply | ✅ passed (Pro 2026.6.2, named volume) |
