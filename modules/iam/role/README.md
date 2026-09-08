<!-- markdownlint-disable-file MD025 MD041 -->
# IAM Role (generic trust-boundary role)

One generic module for standalone **trust-boundary** roles — roles
assumed by other IAM principals
([DESIGN-0025](../../../docs/design/0025-generic-iam-role-module.md)),
replacing the queued `iam/deploy-role` + `iam/cross-account-role`
pair: the two patterns have identical resource surfaces and differ
only in their inputs, so **the inputs define what an instance is**.

Not for service-principal roles (EC2 instance profiles, Lambda
execution roles, `pods.eks.amazonaws.com`) — resource-owning modules
mint their own service roles (`eks/cluster`, `managed-node-group`,
`eks/pod-identity-access`, `bedrock/claude-code` all do).

The worked examples, the adoption runbook, and the remote-state key
contract land in Phase 2 of
[IMPL-0022](../../../docs/impl/0022-generic-iam-role-module.md).

Full variable/output reference: [USAGE.md](USAGE.md).
