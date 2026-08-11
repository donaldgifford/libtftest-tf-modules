<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | ~> 6.2 |
| random | ~> 3.7 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.2 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_secretsmanager_secret.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_policy.read_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_policy) | resource |
| [aws_secretsmanager_secret_version.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_iam_policy_document.read_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| description | Description on the Secrets Manager secret. | `string` | `null` | no |
| kms\_key\_arn | Optional CMK ARN encrypting the secret. Null (default) uses the AWS-managed aws/secretsmanager key — zero cost, but cross-account reads are impossible and consumers see a null kms\_key\_arn output (rds/proxy then uses its ViaService-fenced wildcard). Set a CMK for cross-account reads or exact downstream kms:Decrypt scoping; granting the key policy is out of module scope. | `string` | `null` | no |
| name | Logical secret name. Seeds the aws\_secretsmanager\_secret name\_prefix (the created secret is <name>-<random-suffix>) and is the <name> segment of the ADR-0020 remote-state key consumers compose: <account\_name>/<region>/secrets/<name>/terraform.tfstate. The state-key coupling is to THIS value, not the suffixed physical secret name. | `string` | n/a | yes |
| password\_length | Length of the generated password. | `number` | `32` | no |
| password\_override\_special | Special characters the generator may use. The default is the RDS-legal set (no '/', '@', '"', or space) so the DB-credentials shape works for postgres and mysql master passwords without per-consumer tuning. | `string` | `"!#$%&*()-_=+[]{}<>:?"` | no |
| read\_principals | IAM principal ARNs (roles, users, or account roots) granted read-only access (GetSecretValue + DescribeSecret) via a resource policy on the secret. Empty (default) creates no policy resource at all. Cross-account principals additionally require the BYO-CMK path (var.kms\_key\_arn) plus a kms:Decrypt grant in that key's own policy — the AWS-managed key cannot cross accounts. | `list(string)` | `[]` | no |
| secret\_recovery\_window\_days | Recovery window Secrets Manager holds a deleted secret for. 0 = immediate permanent deletion (test teardown / break-glass); otherwise 7-30 days (AWS API constraint). NB: the secret NAME stays reserved for the length of this window — which is why the module uses name\_prefix (DESIGN-0020 resolution 5a). | `number` | `30` | no |
| secret\_string\_version | Version gate for the write-only secret value (INV-0010 F4). The generated password is only SENT when this integer changes: leave it and applies are no-ops (the in-memory regeneration is discarded unsent); bump it and exactly one new password lands in the secret. Rotation = bump this number. Consumers that copy the value onward do NOT pick the rotation up automatically. | `number` | `1` | no |
| tags | Tags applied to the secret. | `map(string)` | `{}` | no |
| username | Non-secret username half of a DB-credential pair. When set, the secret value is the RDS-format JSON {"username", "password"}; when null (default), the value is the bare generated password. Also emitted as a (non-secret) output for consumer sanity checks. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| kms\_key\_arn | CMK ARN encrypting the secret, or null when the AWS-managed aws/secretsmanager key is in charge (the default). Faithful null matters: rds/proxy keys off it — non-null gets exact kms:Decrypt scoping, null falls back to its ViaService-fenced wildcard path. |
| secret\_arn | ARN of the Secrets Manager secret — the composition pointer. Consumers (the RDS reference mode, rds/proxy) scope their IAM secretsmanager:GetSecretValue to exactly this ARN and read the value ephemerally at apply. |
| secret\_id | Resource ID of the secret (equals the ARN for Secrets Manager; kept for symmetry with the fleet's other producers). |
| secret\_name | Physical (suffixed) secret name — informational. NB: the ADR-0020 remote-state key couples to var.name, NOT this value; consumers resolve the secret by ARN, never by constructing this name. |
| secret\_string\_version | Current value of the write-only version gate — informational. Bumping the input mints one new password (INV-0010 F4); consumers that copy the value onward re-send on their own version bump. |
| username | Non-secret username half of the DB-credential pair (null when the secret is a bare password). Lets consumers sanity-check which credential pair they are pointing at without reading the value. |
<!-- END_TF_DOCS -->