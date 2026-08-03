<!-- markdownlint-disable-file MD025 MD041 -->
# S3 Access-Logs Bucket (the fleet's log sink)

The **server-access-log sink** for the S3 module family
([DESIGN-0019](../../../docs/design/0019-s3-module-family-internal-core-and-initial-bucket-modules.md)):
a zero-configuration singleton that every family bucket's default
access-logging lookup targets. It wraps the family's internal core
(`../internal/core` — never usable directly outside `modules/s3/`) with
the sink's fixed posture:

- **SSE-S3 (`AES256`), never KMS** — S3's log-delivery service does not
  write to SSE-KMS targets, so the encryption mode is pinned, not a
  variable.
- **The log-delivery grant** — `AllowS3ServerAccessLogDelivery` for the
  `logging.s3.amazonaws.com` service principal, objects-only (`/*`),
  conditioned on `aws:SourceAccount` (account-scoped: no per-source
  bucket edits, no cross-account delivery — DESIGN-0019 OQ 2a).
- **90-day retention by default** (`log_retention_days`, `null` retains
  forever — OQ 1a), rendered as the `expire-access-logs` lifecycle rule
  beside the core's MPU-abort hygiene rule.
- **Versioning off** — log objects are write-once noise to version.
- The rest of the family baseline verbatim from the core: full Block
  Public Access, `BucketOwnerEnforced`, both TLS deny statements, name
  composed `<name>-<account_id>-<region>` (default name `access-logs`).

The sink **cannot log to itself** (no `logging` pass-through); its own
access logging stays off by design.

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Zero-configuration usage

```hcl
module "access_logs" {
  source = "../../s3/access-logs-bucket"

  account_id = var.account_id
  region     = var.region
}
# => bucket access-logs-<account_id>-<region>, 90-day retention
```

## Remote-state key contract (ADR-0020)

This module is a pure **producer** (it reads no remote state). Its
state **must be published at the flat reserved key** (i.e. the
Terragrunt live-repo directory must be):

```text
<account_name>/<region>/s3/access-logs/terraform.tfstate
```

Note the shape: **no `<name>` segment**. The family's `bucket` module
composes exactly this key for its default access-logging lookup, so the
stack name `access-logs` is reserved — one sink per account/region at
this path. Consumer set (what that lookup reads): **`bucket_name`**;
`bucket_arn` / `bucket_id` are additive.

**Non-default sinks need no key contract.** To run a second,
differently-shaped sink (e.g. `audit-logs`), deploy this module at any
other live-repo folder and point each consuming bucket at it explicitly
via its `access_logging.target_bucket` override — the consumer then
skips the reserved-key lookup entirely (INV-0009 OQ 2).

## Tests

| Suite | Tier | What it proves |
|-------|------|----------------|
| `tests/` (6 runs) | plan-only, the CI gate | composed default name, grant shape (sid / Service principal / SourceAccount condition / objects-only resource), retention wiring via `lifecycle_rule_ids`, the F3 security-baseline variant (AES256), validation guardrails |
| `tests-localstack/` (1 run) | Community apply (token-free `localstack/localstack:4.4`, `SERVICES=s3,sts`) | the full chain applies for real — bucket, PAB, ownership, SSE, versioning, lifecycle, policy; see [FINDINGS.md](tests-localstack/FINDINGS.md) |

`security_baseline.tftest.hcl` here is the family baseline suite's
**documented F3 variant** (AES256, no tri-state logging variable); the
byte-identical pair the Phase-5 diff guard compares is
`bucket`/`events-bucket`.
