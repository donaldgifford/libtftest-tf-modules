<!-- markdownlint-disable-file MD025 MD041 -->
# Aurora Serverless v2 Module

Provisions an Aurora Serverless v2 cluster (Postgres or MySQL) with a
single `db.serverless` instance, module-managed KMS encryption, AWS-
managed master password via Secrets Manager, and opt-in IAM database
authentication. Network composition flows through
`data.terraform_remote_state.vpc` (S3 backend, same convention as the
EKS modules).

Implements
[IMPL-0007](../../../docs/impl/0007-aurora-serverless-v2-module-implementation.md)
/ [DESIGN-0007](../../../docs/design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.
