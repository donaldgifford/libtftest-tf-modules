<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |
| random | ~> 3.7 |

## Providers

| Name | Version |
| ---- | ------- |
| random | 3.9.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [random_string.shard_prefix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | 12-digit AWS account ID, composed into the bucket name for global uniqueness + provenance. Terragrunt-injected in production; from the shared var-file in tests. | `string` | n/a | yes |
| name | Logical bucket name. Composed into the real bucket name as <name>-<account\_id>-<region> (plus the optional shard prefix). Lowercase alphanumeric + hyphens, 3-37 chars, must start/end alphanumeric — the length cap leaves room for the composed suffix within S3's 63-char limit. | `string` | n/a | yes |
| name\_override | Escape hatch: use this exact bucket name verbatim, skipping <name>-<account\_id>-<region> composition (externally-dictated names). The composed-name length/charset precondition still applies to the override. | `string` | `null` | no |
| region | AWS region, composed into the bucket name for global uniqueness + provenance. Terragrunt-injected in production; from the shared var-file in tests. | `string` | n/a | yes |
| shard\_prefix\_enabled | Opt-in: prepend a stable 5-character random lowercase-alphanumeric prefix to the composed bucket name (<shard>-<name>-<account\_id>-<region>) for key-distribution/sharding. Toggling this after creation renames and therefore REPLACES the bucket. | `bool` | `false` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->