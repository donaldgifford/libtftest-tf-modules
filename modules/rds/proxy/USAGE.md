<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.52.0 |
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_db_proxy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_proxy) | resource |
| [aws_db_proxy_default_target_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_proxy_default_target_group) | resource |
| [aws_db_proxy_endpoint.read_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_proxy_endpoint) | resource |
| [aws_db_proxy_target.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_proxy_target) | resource |
| [aws_iam_role.proxy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.proxy_secret_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_security_group.proxy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.to_db](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_iam_policy_document.proxy_secret_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.proxy_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [terraform_remote_state.target](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allowed\_consumer\_sg\_ids | Security group IDs whose members may reach the proxy on the engine listener port. Empty list (default) leaves the proxy reachable from nowhere — operators add ingress deliberately. The proxy's own SG id is emitted as an output so it can be added to the DB module's allowed\_consumer\_sg\_ids on a subsequent apply. | `list(string)` | `[]` | no |
| connection\_borrow\_timeout | Seconds a client waits to borrow a connection from the pool before timing out. Range: 0 - 3600 (0 = wait indefinitely is not used; AWS caps at 3600). Default 120. | `number` | `120` | no |
| create\_read\_only\_endpoint | When true, create an additional READ\_ONLY proxy endpoint routing to Aurora readers. Only valid for Aurora targets (aurora-cluster / serverless) — a precondition (V3) rejects it on rds-instance, which has no proxy reader routing. Default false. | `bool` | `false` | no |
| db\_port | TCP port the proxy listens on and connects to the DB with. When null (default), derived from the target engine read from remote state (5432 for Postgres, 3306 for MySQL). | `number` | `null` | no |
| debug\_logging | When true, the proxy logs detailed SQL to CloudWatch (useful for debugging, verbose + potentially sensitive). Default false. | `bool` | `false` | no |
| idle\_client\_timeout | Seconds a client connection may sit idle before the proxy closes it. Range: 1 - 28800. Default 1800 (30 minutes, the AWS default). | `number` | `1800` | no |
| init\_query | Optional SQL run on every new database connection the proxy opens (e.g. 'SET x=1; SET y=2'). Null (default) runs no init query. | `string` | `null` | no |
| max\_connections\_percent | Maximum percentage of the target's max\_connections that the proxy may use for its connection pool. Range: 1 - 100. Default 100. | `number` | `100` | no |
| max\_idle\_connections\_percent | Maximum percentage of max\_connections\_percent that the proxy keeps idle in the pool. Range: 0 - 100. Should not exceed max\_connections\_percent — a precondition (V6) enforces that cross-variable bound. Default 50. | `number` | `50` | no |
| name | Name of the RDS Proxy (DESIGN-0010 Q4-a — explicit, operator-chosen). Must begin with a letter, contain only ASCII letters, digits, and hyphens, not end with a hyphen, and be 2-60 characters. AWS additionally rejects two consecutive hyphens at apply time. | `string` | n/a | yes |
| region | AWS region for the proxy and for the S3 backend hosting the target DB module's remote state. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the target DB module's terraform state. The proxy reads <region>/rds/<dir>/<target\_identifier>/terraform.tfstate for the target's outputs (DESIGN-0010 Q3 — remote-state composition). | `string` | n/a | yes |
| require\_iam\_auth | When true, client-to-proxy connections require IAM authentication (auth.iam\_auth = REQUIRED); when false (default), DISABLED. Requires the target to have iam\_database\_authentication\_enabled = true — enforced via a precondition (V4). | `bool` | `false` | no |
| require\_tls | When true (default), the proxy requires TLS for client connections. Recommended on — clients connecting to the proxy endpoint must use TLS. | `bool` | `true` | no |
| session\_pinning\_filters | Connection-pinning filters to relax. The only AWS-supported value is 'EXCLUDE\_VARIABLE\_SETS' (avoids pinning on SET statements). Empty list (default) keeps all pinning behaviour. | `list(string)` | `[]` | no |
| tags | AWS resource tags applied to every taggable resource in the module (proxy, target group, endpoint, IAM role, security group). | `map(string)` | `{}` | no |
| target\_identifier | Identifier of the target DB instance or cluster. Used both to compose the remote-state key (<region>/rds/<dir>/<target\_identifier>/terraform.tfstate) and as the db\_instance\_identifier / db\_cluster\_identifier on the proxy target. | `string` | n/a | yes |
| target\_type | Discriminator selecting which data-tier module the proxy fronts: 'rds-instance' (single aws\_db\_instance), 'aurora-cluster' (Aurora provisioned), or 'serverless' (Aurora Serverless v2). Selects the remote-state key shape and whether the proxy target is keyed by db\_instance\_identifier or db\_cluster\_identifier. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| proxy\_arn | ARN of the RDS Proxy. |
| proxy\_endpoint | Default (writer) proxy endpoint hostname. Applications connect here for read+write workloads, in place of the DB cluster/instance writer endpoint. |
| proxy\_name | Name of the RDS Proxy (var.name). Used to compose this proxy's own remote-state key for downstream consumers. |
| proxy\_role\_arn | ARN of the IAM role the proxy assumes to read and decrypt the target's AWS-managed master secret. |
| proxy\_security\_group\_id | Security group ID of the proxy. Pass this into the target DB module's allowed\_consumer\_sg\_ids on a subsequent apply so the DB tier admits the proxy on the engine port (the reciprocal of the proxy's egress-to-DB rule — DESIGN-0010 Q3). |
| read\_only\_endpoint | Hostname of the READ\_ONLY proxy endpoint when var.create\_read\_only\_endpoint is set on an Aurora target; null otherwise. Routes read traffic to Aurora readers. |
<!-- END_TF_DOCS -->
