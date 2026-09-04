<!-- markdownlint-disable-file MD025 MD041 -->
# S3 Evidence Bucket

Evidence-grade retention
([DESIGN-0022](../../../docs/design/0022-s3-evidence-bucket-and-lifecycle-tiering-exposure.md)
/ INV-0011 F4): a [`s3/bucket`](../bucket/) fork with the evidence
posture **pinned** — versioning Enabled and S3 Object Lock on,
neither exposed as a variable — and the retention surface as its one
new input. Built for the platform's "harness-removal" requirement:
Loki archives and audit data whose retention **no principal can
shorten**.

## ⚠️ COMPLIANCE mode is unfixable by design

`retention.mode` defaults to **COMPLIANCE**: until a locked version's
retention expires, *no principal — environment admins, hub admins, or
root — can shorten its retention or delete it*. That is the point,
and it cuts both ways:

- A fat-fingered long retention (`years = 10` for `days = 10`) is
  **not recoverable**. The locked versions survive until expiry, and
  a bucket holding locked versions **cannot be deleted at all**.
- `force_destroy` does not override lock retention (S3 semantics, not
  module policy) — it only deletes what is deletable.
- The retention duration is therefore **required, with no default**
  (DESIGN-0022 OQ 1a): every stack states its retention explicitly.
  The retention period is the design decision.

`GOVERNANCE` stays selectable for lower-stakes tiers — it is
bypassable by principals holding `s3:BypassGovernanceRetention`.

## Usage

```hcl
module "loki_archive" {
  source = "../../modules/s3/evidence-bucket"

  name = "loki-archive"

  retention = {
    days = 400 # COMPLIANCE by default; exactly one of days/years
  }

  # Evidence ages to Glacier while retention holds (transitions are
  # lock-compatible); noncurrent versions expire after retention.
  lifecycle_rules = [{
    id = "tier-and-expire"
    transitions = [
      { days = 90, storage_class = "GLACIER_IR" },
    ]
    noncurrent_version_expiration_days = 730
  }]

  # Terragrunt-provided globals (injected via include in production)
  account_name               = var.account_name
  account_id                 = var.account_id
  region                     = var.region
  remote_state_bucket        = var.remote_state_bucket
  remote_state_bucket_region = var.remote_state_bucket_region
  deploy_role_name           = var.deploy_role_name
}
```

## Retention and expiration interplay

- The default retention applies to **new object versions at write
  time**; changing it later affects future versions only.
- Lifecycle **expiration** of a locked version is deferred by S3
  until its retention passes — an expiration rule shorter than the
  retention window silently waits (S3 behavior, not an error).
  Noncurrent-version expiration + Object Lock is the standard
  evidence pattern: versions become noncurrent, wait out retention,
  then expire.
- Storage-class **transitions** are unaffected by lock status —
  tiering locked evidence to Glacier is legal and expected (the cost
  story for long retention).

## Brownfield: existing buckets cannot be locked here

`object_lock_enabled` is **create-time**. The AWS-support `token`
path for enabling lock on an existing bucket exists in the provider
but is deliberately not exposed (DESIGN-0022 Non-Goals): brownfield
adoption = create a new evidence bucket through this module and copy
the data in.

## Everything else is the `bucket` surface

Composed naming (+ optional shard prefix), the F2 security baseline
from the internal core (PAB, BucketOwnerEnforced, SSE-KMS + bucket
key, TLS denies, MPU-abort hygiene), the access-logging tri-state
(default = the reserved fleet-sink lookup), additive
`additional_policy_statements` with the reserved-sid guard, and the
full typed `lifecycle_rules` surface. See the
[`s3/bucket` README](../bucket/README.md) for those contracts.

The `security_baseline` test suite here is the family's documented
**versioning variant** (asserts `Enabled`, not `Suspended`) and is
excluded from the byte-identical diff guard; lock facts ride the
evidence-only `object_lock` output so the shared baseline shape is
untouched (DESIGN-0022 OQ 7a).

## Remote-state key contract

A normal named stack at the standard ADR-0020 shape —
`<account_name>/<region>/s3/<name>/terraform.tfstate` (no reserved
flat key; that is unique to the access-logs sink singleton).

Full variable/output reference: [USAGE.md](USAGE.md).
