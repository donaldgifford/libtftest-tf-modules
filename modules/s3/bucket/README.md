<!-- markdownlint-disable-file MD025 MD041 -->
# S3 Bucket (general-purpose)

The S3 family's **general-purpose secure bucket**
([DESIGN-0019](../../../docs/design/0019-s3-module-family-internal-core-and-initial-bucket-modules.md)
Phase 3 / INV-0009 F1) and its reference consumer — the fleet's first
count-gated remote-state read.

The whole F2 security baseline comes verbatim from the family's
internal core (`../internal/core`) and has **no variables at all**
where the control is fixed:

| Control | Shape |
|---|---|
| Block Public Access | all four flags on, always |
| Object ownership | `BucketOwnerEnforced` (ACLs disabled) |
| Transport | `DenyInsecureTransport` + `DenyOldTls` (< TLS 1.2) policy denies, always |
| Encryption | SSE-KMS + bucket key; AWS-managed `aws/s3` by default, CMK via `kms_key_arn` |
| Versioning | off by default (`versioning_enabled`) — an explicit operator decision |
| Lifecycle | MPU-abort after 7 days (`abort_incomplete_multipart_days`) |
| Naming | `<name>-<account_id>-<region>`, optional 5-char shard prefix |

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Access-logging tri-state

`var.access_logging` has exactly three shapes:

```hcl
# 1. Default — look the fleet sink up at the reserved ADR-0020 key.
access_logging = {}

# 2. Explicit sink — no remote-state read is created.
access_logging = { target_bucket = "audit-logs-000000000000-us-east-1" }

# 3. Deliberately log-less.
access_logging = { enabled = false }
```

`prefix` defaults to `<this bucket's composed name>/` — resolved inside
the core, because only it knows the final name (the shard prefix is
unknown until apply). Setting `target_bucket` or `prefix` alongside
`enabled = false` fails at plan rather than being silently ignored.

## Remote-state key contract (ADR-0020)

On the **default** tri-state path this module reads the access-logs
sink at the flat reserved key:

```text
<account_name>/<region>/s3/access-logs/terraform.tfstate
```

Note the shape: **no `<name>` segment** — `access-logs` is a reserved
stack name, so the producer (`s3/access-logs-bucket`) must be deployed
at that live-repo folder. There is no name input to get wrong; the
consumer set is the sink's `bucket_name` output.

**The read is count-gated**, so paths 2 and 3 above create no data
source at all and need no sink to exist.

**Bootstrapping order:** in a fresh account+region the reserved
`s3/access-logs` stack applies first. Until it does, a bucket stack on
the default tri-state fails its plan with the documented
loud-but-vague `Unable to find remote state` (the error names neither
bucket nor key — diff against the path above). A deliberately log-less
stack sidesteps the ordering entirely with
`access_logging = { enabled = false }`.

The composed key is pinned by a plan assertion in
`tests/default.tftest.hcl`; see ADR-0020 for the fleet table.

## Additional policy statements

`additional_policy_statements` appends operator statements into the
core-composed bucket policy (DESIGN-0019 OQ 4b). The merge is
**additive-only**: the baseline denies always render, and reusing a
reserved sid (`DenyInsecureTransport`, `DenyOldTls`,
`DenyOutsideVpce`) fails at plan.

```hcl
additional_policy_statements = [{
  sid        = "AllowCiReadOnly"
  principals = { AWS = ["arn:aws:iam::123456789012:role/ci-reader"] }
  actions    = ["s3:GetObject"]
  # resource_suffixes defaults to ["", "/*"] — the bucket and its
  # objects. Suffixes are relative to this bucket's ARN because an
  # input cannot reference the module's own output.
}]
```

## Tests

| Suite | Tier | What it proves |
|-------|------|----------------|
| `tests/` (9 runs) | plan-only, the CI gate | all three tri-state paths (resolved target/prefix, zero data-source instances on the no-read paths), the ADR-0020 key composition, the additive policy merge + `resource_suffixes` expansion, the security baseline, and the validation guardrails |
| `tests-localstack/` (3 runs) | Community apply (token-free `localstack/localstack:4.4`, `SERVICES=s3,sts`) | the count-gated read end to end — the fixture applies the **real** `access-logs-bucket` module and seeds the reserved key, which this module reads back through `assume_role`; see [FINDINGS.md](tests-localstack/FINDINGS.md), including the negative F6 probe on log-delivery materialization |

`security_baseline.tftest.hcl` is the family's **canonical** baseline
suite — `events-bucket`'s copy must stay byte-identical (guarded by a
`diff -q` check); `access-logs-bucket` carries the documented F3
variant (AES256).
