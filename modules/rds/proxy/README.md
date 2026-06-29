<!-- markdownlint-disable-file MD025 MD041 -->
# RDS Proxy Module

Places an Amazon RDS Proxy in front of an RDS or Aurora data-tier module.
Composition flows through `data.terraform_remote_state` (S3 backend, the
fleet's ADR-0001 convention): the proxy reads the target DB module's outputs —
master secret ARN, security group, subnet IDs, VPC, secret CMK, engine, and the
instance/cluster identifier — keyed on `var.target_type` +
`var.target_identifier`. A single module serves `rds-instance`,
`aurora-cluster`, and `serverless` targets via `var.target_type`.

Implements
[IMPL-0010](../../../docs/impl/0010-rds-proxy-module-implementation.md)
/ [DESIGN-0010](../../../docs/design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.

> **Status:** under construction (IMPL-0010). Full operator documentation —
> quickstart, SG-wiring instructions, the Serverless v2 cost caveat, and
> operational gotchas — lands in Phase 12.
