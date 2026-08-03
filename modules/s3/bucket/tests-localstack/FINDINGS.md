<!-- markdownlint-disable-file MD025 MD041 -->
# tests-localstack findings — modules/s3/bucket

## Summary

The general-purpose bucket is **pure S3 + STS**, so it applies against
**LocalStack Community** with no Pro tier, no auth token, and no
named-volume workaround. The suite exercises the F4 access-logging
tri-state for real, including the fleet's first **count-gated
remote-state read** — the fixture applies the *actual*
`access-logs-bucket` module and seeds its contract output at the
reserved ADR-0020 key, which this module then reads back through the
account-scoped + `assume_role` path (IMPL-0015).

## Environment (verified 2026-08-02)

| Component | Value |
|-----------|-------|
| Image | `localstack/localstack:4.4` (Community) |
| Services | `SERVICES=s3,sts` |
| Startup | token-free; healthy in ~15s |
| Result | `just tf test-localstack s3/bucket` → **3 passed, 0 failed** |

## What the apply exercised

- `run "setup"` — creates the fleet state bucket, applies the **real**
  `access-logs-bucket` module, and writes its `bucket_name` /
  `bucket_arn` to
  `sandbox/us-east-1/s3/access-logs/terraform.tfstate` (the
  composing-fixture precedent from `rds/proxy`'s `fixtures/db`;
  `override_data` cannot reference prior-run outputs). No VPC is
  involved — unlike the RDS fixtures this suite needs only S3, so it
  skips the shared `reference-vpc` (and its ~1–2 min NAT).
- `run "apply_with_looked_up_sink"` — the default tri-state resolved
  `logging_target` to the name the fixture's sink *actually* produced,
  proving the read mechanics end to end: LocalStack's STS mints
  credentials for the `arn:aws:iam::000000000000:role/Deploy-Tf-Role`
  ARN with no pre-created IAM role, and the global `AWS_ENDPOINT_URL`
  routes both STS `AssumeRole` and the S3 state GET (no `endpoints{}`
  entry needed inside the `terraform_remote_state` config). The null
  prefix resolved to `<composed-name>/` post-apply; the F2 baseline
  held.
- `run "apply_with_explicit_target"` — the override path created zero
  `data.terraform_remote_state` instances on a real apply and passed
  the explicit prefix through verbatim.

The provider needs `s3_use_path_style = true`, and the remote-state
config carries `use_path_style = true` for the same reason.

## F6 probe 1 — server-access-log delivery: **NEGATIVE**

Manual probe (DESIGN-0019 OQ 4a: probe first, bake only the assertable
depth), run outside `terraform test` against the same container:

1. Created `probe-sink` (with the module's exact
   `AllowS3ServerAccessLogDelivery` policy — Service principal +
   `aws:SourceAccount`) and `probe-source`.
2. `put-bucket-logging` on `probe-source` targeting the sink with
   prefix `probe-source/`.
3. Generated 10 requests (5 PUT + 5 GET) against `probe-source`.
4. Polled the sink at 60 s and ~150 s.

**Result:** the sink stayed empty (`ListObjectsV2` returned no
`Contents`), and the container log contains no delivery activity.
LocalStack Community 4.4 **stores and returns the logging
configuration faithfully** (`get-bucket-logging` round-trips
`TargetBucket` + `TargetPrefix`) but does not materialize delivered
log objects. Real AWS is also best-effort with hours of latency, so
delivery is not testable in a suite either way.

**Consequence (DESIGN-0019 OQ 6a fallback):** the suite asserts the
**configuration surface** — the resolved `logging_target` /
`logging_prefix` (attribute-derived from `aws_s3_bucket_logging`), the
grant statement in the sink's applied policy (pinned in
`access-logs-bucket`'s own suites) — and does **not** assert delivered
objects. That is the full assertable depth; no test was written that
would pass vacuously.

## To reproduce

```bash
docker run -d --name ls-s3-bucket -p 4566:4566 \
  -e SERVICES=s3,sts localstack/localstack:4.4
# wait for /_localstack/health to report s3 available, then:
just tf test-localstack s3/bucket
docker rm -f ls-s3-bucket
```
