# s3 internal core

> **INTERNAL MODULE — do not consume from a Terragrunt stack.** This
> module is the shared security core of the `modules/s3/` family and is
> consumed **only** by its sibling purpose modules via the relative path
> `source = "../internal/core"`. It is not a valid live-repo target and
> publishes no remote-state contract.

The one deliberate exception to the fleet's no-module-in-module rule
(DESIGN-0019 / INV-0009 OQ 1c): the nesting is invisible to Terragrunt
(one consumable purpose module per stack still holds), and the
relative-path source means the core rides each purpose module's release
tag — there is no independent core version to drift.

**Standing condition:** this module must **never** gain a versioned
source (registry or git-ref). If it ever does, the nesting exemption is
void and the family reverts to the duplicated-core shape (INV-0009
OQ 1a). A static-gate grep enforces this (IMPL-0018 Phase 5).

## What it owns

Every baseline resource of a family bucket (DESIGN-0019 F2 baseline):

- The `aws_s3_bucket` with composed global-unique naming
  (`<name>-<account_id>-<region>`), a `name_override` escape hatch, and
  an opt-in 5-character random shard prefix
  (`<shard>-<name>-<account_id>-<region>`).
- Block Public Access (all four flags, fixed on).
- Ownership controls: `BucketOwnerEnforced` (fixed — ACLs disabled).
- Encryption: SSE-KMS with the AWS-managed `aws/s3` key +
  `bucket_key_enabled` by default, CMK override, or SSE-S3 (`AES256`)
  for the access-logs sink.
- Versioning (off by default — operator decision, INV-0009 F2).
- Lifecycle hygiene: abort-incomplete-multipart-upload (7 days default)
  plus caller-supplied extra rules.
- The composed bucket policy: fixed HTTPS-only + TLS >= 1.2 denies,
  opt-in VPCE-only restriction, and additive purpose-module statement
  injection (reserved-sid validation — injected statements can never
  shadow the baseline).
- Server-access-logging wiring (`logging` object pre-resolved by the
  caller; the remote-state lookup lives in the purpose modules).

## What it deliberately does not own

- `data.terraform_remote_state` reads (read-at-use-site; ADR-0020 plan
  assertions require a root-module data source).
- The Terragrunt globals surface (only `account_id` + `region` for name
  composition are passed in).
- Any type-specific surface (notifications, log-delivery grants,
  retention defaults) — those live in the purpose modules.

## Testing

The core is tested **directly** by its own plan-only `tests/` suite —
as the root module its resources are directly assertable, which the
purpose modules' suites cannot do (child-module resources are not
addressable in `terraform test` assertions). The purpose modules pin
the *composed result* via the re-exported `security_baseline` output
and one identical `security_baseline.tftest.hcl` per module.

Run: `just tf test s3/internal/core`
