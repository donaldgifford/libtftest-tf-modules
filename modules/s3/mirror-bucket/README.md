<!-- markdownlint-disable-file MD025 MD041 -->
# S3 Mirror Bucket (provider network mirror)

The S3 family's **provider-mirror serving bucket**
([DESIGN-0028](../../../docs/design/0028-s3-mirror-bucket-purpose-module.md)
— sluice workstream 2, gh-121): a thin wrapper over the internal core
(`../internal/core`) that ships the mirror's security posture —
VPC-only anonymous reads, deny-delete by default, admin-pinned
policy-mutation guard — reviewed once, here.

Pinned posture (**no variables** — posture that must not drift is not
exposed):

| Control | Shape |
|---|---|
| Block Public Access | all four flags on, always |
| Object ownership | `BucketOwnerEnforced` (ACLs disabled) |
| Transport | `DenyInsecureTransport` + `DenyOldTls` (< TLS 1.2) policy denies, always |
| Encryption | **SSE-S3/AES256 pinned** — anonymous readers cannot decrypt SSE-KMS objects |
| Versioning | **pinned on** — mirror artifacts are immutable releases |
| Lifecycle | MPU-abort after 7 days + opt-in noncurrent→IA rule (`noncurrent_version_ia_days`); **never expiration** |
| Object Lock | opt-in (`enable_object_lock` + `object_lock_retention_days`), COMPLIANCE pinned |
| Naming | `<name>-<account_id>-<region>`; the sluice-dictated mirror name arrives via `name_override` |

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Policy statements

All four compose in root `locals` and inject through the core's
additive `internal_policy_statements` channel (full statement
reference in DESIGN-0028):

| Sid | Shape |
|---|---|
| `AllowMirrorReadFromVPCE` | allow `s3:GetObject` to `*` on objects only, conditioned on `aws:SourceVpce` |
| `DenyOutsideVpce` | the core's opt-in — deny `s3:*` outside `vpc_endpoint_ids` |
| `DenyObjectDeletion` | deny deletes to `*`; **unconditional when `break_glass_principal_arns` is empty**, `NotIn` exception otherwise |
| `DenyPolicyMutation` | deny `PutBucketPolicy`/`DeleteBucketPolicy` outside `policy_admin_principal_arns` (disable via `enable_policy_mutation_guard`) |

`policy_admin_principal_arns` is required non-empty: an empty admin
list would strand the stack (nobody could ever amend the policy).

## Break-glass runbook

Content mistakes fix forward with new object versions. A true purge
(malware takedown) is a reviewed PR that adds a principal to
`break_glass_principal_arns`, applies, deletes, and reverts. The
escape hatch is the change process, not a standing role.

## Object Lock warning

`enable_object_lock` is **create-time**: toggling it on an existing
bucket **replaces the bucket**, and it cannot be retrofitted via any
`token` path — brownfield means a new bucket plus copy. With
COMPLIANCE default retention, locked versions are undeletable by
anyone (including root) until expiry, and a bucket holding locked
versions cannot be deleted at all: a fat-fingered long
`object_lock_retention_days` is unfixable, so state the duration
explicitly per stack and keep sandbox mirrors unlocked.

## No IAM resources

The GitHub OIDC publisher role is provisioned out of band.
Same-account publishing needs no bucket-policy grant; cross-account
publishers arrive via `cross_account_publisher_principal_arns`
(write-only, no deletes).

## Explicit logging target

`access_log_bucket` names the sink bucket directly (`null`
disables) — no fleet remote-state lookup, no bootstrapping order
beyond applying the sink first. The sink is the existing
`access-logs-bucket` stack.
