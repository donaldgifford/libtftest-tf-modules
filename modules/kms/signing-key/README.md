<!-- markdownlint-disable-file MD025 MD041 -->
# KMS Signing Key (cosign)

An asymmetric `SIGN_VERIFY` KMS key for signing container images and
attestations with cosign
([DESIGN-0031](../../../docs/design/0031-ecr-image-intake-and-kms-signing-key-modules.md)).
Its key policy names exactly who may administer, sign and verify, and
**delegates nothing to account IAM**.

## One key per signing class

Create one instance per thing a signature vouches for, and name it with
a placeholder-style class name:

- one key for intake's mirror signatures (`example-mirror-signing`);
- one per CI system for first-party images (`example-ci-signing`).

An admission policy can then trust a key for exactly what it vouches
for. Sharing one key across classes means a compromise of the weakest
signer forges signatures for all of them.

## The key policy

| Statement | Principals | Actions |
| --- | --- | --- |
| `KeyAdministration` | `admin_principal_arns` | Everything **except** `kms:Sign` (`NotAction`) |
| `AllowSign` | `signer_principal_arns` | `kms:Sign`, `kms:GetPublicKey`, `kms:DescribeKey` |
| `AllowVerify` (only when set) | `verifier_principal_arns` | `kms:Verify`, `kms:GetPublicKey`, `kms:DescribeKey` |

There is **no** `arn:aws:iam::<account>:root` statement. Without it,
account IAM cannot grant `kms:Sign`, so a broad admin role holding
`kms:*` on `*` through an identity policy still cannot sign. Only the
key policy makes a signer. Admins cannot sign either, and signers and
admins must be disjoint (enforced at plan).

Because nothing delegates to IAM, the role that applies this module
must be in `admin_principal_arns`. A precondition checks that at plan,
comparing the caller's assumed-role ARN with the admin list in the
normalized `<account>/<role-name>` form. Without it, the next apply
could not update the key policy. Every principal list rejects account
roots, wildcards, padded ARNs and duplicates.

## Usage

```hcl
module "mirror_signing" {
  source = "git::https://github.com/donaldgifford/libtftest-tf-modules.git//modules/kms/signing-key?ref=<tag>"

  name                  = "example-mirror-signing"
  admin_principal_arns  = ["arn:aws:iam::111111111111:role/example-deploy"]
  signer_principal_arns = ["arn:aws:iam::111111111111:role/example-intake"]
}
```

Sign with the `cosign_key_ref` output:

```sh
cosign sign --yes --key "awskms:///<key ARN>" \
  --signing-config signing-config.no-tlog.json \
  "<registry>/mirror/...@sha256:<digest>"
```

`ecr/image-intake`'s README and `examples/promote.sh` show the full
promotion step, including the cosign 3 signing config that turns off
the transparency-log upload.

## Use the key ARN, never the alias

KMS aliases do not resolve across accounts. `cosign_key_ref` is
therefore `awskms:///<key ARN>`, and every cross-account reference
should use `key_arn`. `alias_arn` is for same-account convenience only.

## Verifying across accounts

Most verifiers need **no KMS access at all**. Give admission
controllers and `cosign verify --key` the `public_key_pem` output. A
public key can be shared freely, and verification then works offline,
in any account.

Use `verifier_principal_arns` only for a verifier that must call
`kms:Verify` itself. A verifier or signer in **another** account also
needs an identity-side grant in its own account. For signers, the
`signer_policy_json` output is that grant.

## Rotation

`enable_key_rotation = false` is pinned: AWS does not rotate asymmetric
keys. Rotating a signing key means a **new key** (a new instance of
this module) and an overlap period in which verifiers trust both public
keys, until every image signed with the old key has been re-signed or
retired.

Changing `key_spec` replaces the key, with the same consequence:
existing signatures need the old public key to verify.

## Destroy

There is no `prevent_destroy`. It would make the apply suite's teardown
impossible, and `lifecycle` arguments cannot be switched for tests
only. The guard is the deletion window: **30 days**, the maximum.
Within it, `aws kms cancel-key-deletion` restores the key. A deleted
key leaves every signature it made unverifiable unless the public key
was kept, so keep `public_key_pem` wherever verifiers read it.

## Tagging

There is no `tags` input (DESIGN-0029). The key and alias receive the
provider's `default_tags`.

## LocalStack

Token-free Community 4.4 serves KMS signing, so the module has a real
Community apply suite. It proves wiring only: 4.4 does **not** enforce
key policies (a deny-all policy still signs) and accepts rotation on an
asymmetric key. The plan suite owns both. See
[`tests-localstack/FINDINGS.md`](tests-localstack/FINDINGS.md).

## Tests

| Suite | Tier | What it proves |
| --- | --- | --- |
| `tests/` | plan (the gate), 20 runs | A bare call pinning usage, spec, rotation off and the deletion window; the key policy decoded statement by statement with no root delegation; outputs; the caller precondition against a path-bearing admin ARN; 14 rejections, each verified by isolated message probe to fire its own rule |
| `tests-localstack/` | Community apply, 2 runs | The key, alias and public key against token-free 4.4, read back through the alias in a separate fixture |

Enforcement against real KMS is part of `ecr/image-intake`'s sandbox
runbook: the intake role signs, and a key admin calling `kms:Sign` is
refused.

## Related modules

- [`ecr/image-intake`](../../ecr/image-intake/README.md): the intake
  role named in `signer_principal_arns` promotes and signs images.
- [`ecr/registry`](../../ecr/registry/README.md): shares the signed,
  promoted prefixes with consumer accounts.

Full variable and output reference: [USAGE.md](USAGE.md).
