# LocalStack findings — kms/signing-key

Community apply suite (`apply_localstack.tftest.hcl`) against
**token-free `localstack/localstack:4.4` (Community),
`SERVICES=kms,sts`**. Run and passing, **2/2** (2026-11-13). Pure KMS
and STS: no Pro tier, no auth token, no named volume.

## ⚠️ Read first: two 4.4 gaps this tier cannot see past

Both were probed directly against the same container on 2026-11-13
with the AWS CLI, outside the suite.

| Gap | Probe | 4.4 result | Real AWS |
| --- | --- | --- | --- |
| Key policy is **not enforced** | `CreateKey` with a policy that denies `kms:*` to `*`, then `Sign` | Signs (`ECDSA_SHA_256`) | `AccessDeniedException` |
| Rotation is **accepted on an asymmetric key** | `EnableKeyRotation` on an `ECC_NIST_P256` `SIGN_VERIFY` key | Accepted; `GetKeyRotationStatus` returns `true` | `UnsupportedOperationException` |

So a green apply here says **nothing** about who can sign, and nothing
about whether the rotation pin is right. Both are owned by the plan
suite instead:

- the key policy's shape (no root delegation, `KeyAdministration`
  carrying `NotAction: kms:Sign`, `AllowSign`, optional `AllowVerify`)
  is decoded and asserted in `tests/key.tftest.hcl`;
- `enable_key_rotation = false` is asserted by the bare-call run.

Policy **enforcement** is the sandbox tier's job (IMPL-0027 Phase 7):
a principal outside `AllowSign` must get `AccessDenied` from real KMS.

## What the suite does assert

| Assertion | Why it is meaningful |
| --- | --- |
| Key is `SIGN_VERIFY` / `ECC_NIST_P256` | The usage and spec the module asked for are what KMS created |
| `public_key_pem` starts with `-----BEGIN PUBLIC KEY-----` | `GetPublicKey` serves the key, and the data source that depends on the pending key resolves after apply. It is unknown at plan, which is why the plan suite cannot assert it |
| `cosign_key_ref == awskms:///<key ARN>` | The ARN form, not the alias: aliases do not resolve cross-account |
| `alias_name == alias/<name>` | The alias wiring |

The `verify_readback` run then resolves the alias **back** through
`data.aws_kms_alias` and `data.aws_kms_key` in a separate fixture
(`fixtures/verify`). It confirms the alias targets the module's key and
that KMS serves back the usage and spec. That checks the far side, not
what the provider recorded.

## The caller precondition on LocalStack

The module requires the applying principal to be in
`admin_principal_arns`. The suite's provider uses an `assume_role`
block for `arn:aws:iam::000000000000:role/deploy`. LocalStack STS mints
credentials for any role ARN (IMPL-0015 Phase 1), so the caller becomes
an `assumed-role/deploy/...` ARN. That is the shape an Atlantis deploy
role presents, and the precondition normalizes it to `000000000000/deploy`.
This exercises the normalization live, not just under the plan mock.

## Running it

```sh
docker run -d --rm --name ls44 -p 4566:4566 \
  -e SERVICES=kms,sts localstack/localstack:4.4
just tf test-localstack kms/signing-key
```

Teardown schedules the key for deletion; LocalStack honours the 30-day
window, so keys accumulate in a long-lived container. Restart it to
clear them.
