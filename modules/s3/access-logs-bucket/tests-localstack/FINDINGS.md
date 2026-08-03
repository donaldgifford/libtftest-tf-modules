<!-- markdownlint-disable-file MD025 MD041 -->
# tests-localstack findings — modules/s3/access-logs-bucket

## Summary

The access-logs sink is **pure S3 API**, so its full resource chain —
bucket, Public Access Block, ownership controls, SSE-S3 encryption
configuration, versioning, lifecycle configuration, and bucket policy
— applies cleanly against **LocalStack Community**: no Pro tier, no
auth token, no named-volume workaround (contrast the RDS family). The
`apply_localstack.tftest.hcl` suite runs `command = apply` for real,
with no fixture (the sink is a pure producer — no remote-state reads).

## Environment (verified 2026-08-02)

| Component | Value |
|-----------|-------|
| Image | `localstack/localstack:4.4` (Community) |
| Services | `SERVICES=s3,sts` |
| Startup | token-free; healthy in ~15s |
| Result | `just tf test-localstack s3/access-logs-bucket` → **1 passed, 0 failed** |

Newer Community images (2026.6.x) gate startup behind an auth token
(container exits 55). The `4.4` image predates that gate and starts
token-free (IMPL-0018 OQ 5a — pin held fleet-wide until the
hobby-account / floci-testcontainers replacement lands).

## What the apply exercised

`run "apply_sink"` created the zero-configuration singleton and
asserted the applied shape end-to-end:

- Composed default name `access-logs-000000000000-us-east-1` and its
  ARN (account_id/region from the shared
  `test/fixtures/terragrunt-inputs.tfvars`).
- `security_baseline` fully attribute-derived post-apply: all four
  Block Public Access flags on, `BucketOwnerEnforced`, `AES256`,
  versioning `Suspended`, MPU-abort 7 days, both TLS deny sids.
- Default 90-day retention rule present in `lifecycle_rule_ids`.
- The `AllowS3ServerAccessLogDelivery` grant present in the applied
  bucket policy — LocalStack accepts the `logging.s3.amazonaws.com`
  Service principal with the `aws:SourceAccount` condition verbatim.

Teardown destroyed the empty bucket without `force_destroy`. The
provider needs `s3_use_path_style = true` (virtual-host style would
address `<bucket>.localhost`). **No gaps.**

## To reproduce

```bash
docker run -d --name ls-s3-sink -p 4566:4566 \
  -e SERVICES=s3,sts localstack/localstack:4.4
# wait for /_localstack/health to report s3 available, then:
just tf test-localstack s3/access-logs-bucket
docker rm -f ls-s3-sink
```
