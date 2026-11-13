<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.2 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_kms_public_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_public_key) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_principal\_arns | Principals that administer the key (everything except kms:Sign). Must include the role that applies this module: the key policy delegates nothing to account IAM, so a deploy role missing from this list is locked out on the next apply (enforced by a precondition). Admins deliberately cannot sign. | `list(string)` | n/a | yes |
| key\_spec | Asymmetric key spec. ECC\_NIST\_P256 (default) is cosign's default; RSA\_4096 is for verifiers that cannot handle ECDSA (DESIGN-0031 OQ 4a). Changing it REPLACES the key, and every existing signature then needs the old public key to verify. | `string` | `"ECC_NIST_P256"` | no |
| name | Key name: the alias becomes alias/<name>. Use a placeholder-style class name (for example example-mirror-signing), one instance per signing class. Renaming replaces the alias (not the key). | `string` | n/a | yes |
| signer\_principal\_arns | Principals allowed kms:Sign (plus GetPublicKey and DescribeKey). Only these can vouch with the key; account-wide IAM grants cannot add signers. A cross-account signer also needs the identity grant in signer\_policy\_json. | `list(string)` | n/a | yes |
| verifier\_principal\_arns | Optional principals allowed kms:Verify (plus GetPublicKey and DescribeKey), possibly in other accounts. Most verifiers should use the public\_key\_pem output instead and need no KMS access at all. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alias\_arn | The alias ARN. Same-account use only: KMS aliases cannot be used across accounts. |
| alias\_name | The alias name (alias/<name>). |
| cosign\_key\_ref | The cosign --key reference: awskms:///<key ARN>. Uses the key ARN, never the alias, because aliases do not resolve across accounts. |
| key\_arn | The key ARN. |
| key\_id | The key ID. |
| public\_key\_pem | The PEM-encoded public key, for verifiers and admission controllers that should not need KMS access. |
| signer\_policy\_json | The identity-side grant a CROSS-ACCOUNT signer needs (kms:Sign, GetPublicKey, DescribeKey on this key). Same-account signers are already covered by the key policy. |
<!-- END_TF_DOCS -->