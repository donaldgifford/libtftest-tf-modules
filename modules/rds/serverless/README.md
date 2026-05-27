<!-- markdownlint-disable-file MD025 MD041 -->
# Aurora Serverless v2 Module

Provisions an Aurora Serverless v2 cluster (Postgres or MySQL) with a
single `db.serverless` instance, module-managed KMS encryption,
AWS-managed master password via Secrets Manager, and opt-in IAM
database authentication. Network composition flows through
`data.terraform_remote_state.vpc` (S3 backend, same convention as the
EKS modules).

Implements
[IMPL-0007](../../../docs/impl/0007-aurora-serverless-v2-module-implementation.md)
/ [DESIGN-0007](../../../docs/design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Prerequisites

1. **VPC stack landed first** — applied to the same AWS account +
   region as the cluster, with state written to S3 at
   `<region>/vpc/<vpc_name>/terraform.tfstate`. Required outputs in
   the state file: `vpc_id`, `private_subnet_ids` (per IMPL-0007 Q1 —
   reuses the EKS-cluster remote-state contract). The subnets must
   span at least two availability zones (Aurora requirement).
2. **S3 backend bucket** exists and is reachable from the runner
   applying this module.
3. **LocalStack** — optional. The `tests-localstack/` suite expects a
   container on `:4566`. Defaults to LocalStack Community (per
   DESIGN-0007 Q7); Pro 2026.5.0 is also supported and verified
   tier-agnostic.

## Instantiation

### Minimal Postgres example

```hcl
module "platform_db" {
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/rds/serverless?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "platform-db"

  engine  = "aurora-postgresql"
  min_acu = 0.5
  max_acu = 16

  allowed_consumer_sg_ids = [
    "sg-0123456789abcdef0", # backend app SG
  ]

  tags = {
    Service     = "platform-api"
    Environment = "production"
  }
}
```

### Minimal MySQL example

```hcl
module "analytics_db" {
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/rds/serverless?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "analytics-db"

  engine  = "aurora-mysql"
  min_acu = 0.5
  max_acu = 4

  allowed_consumer_sg_ids = ["sg-aaa1234567"]

  tags = { Service = "analytics" }
}
```

### Bring-your-own KMS

```hcl
module "compliance_db" {
  source = "..."

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "compliance-db"

  engine      = "aurora-postgresql"
  min_acu     = 0.5
  max_acu     = 8
  kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/abc-def-ghi"
}
```

When `kms_key_arn` is set, the module skips its internal key + alias.
The same caller-supplied key encrypts both cluster storage at rest and
the master user secret (per IMPL-0007 Q12).

### Opt-in IAM database authentication

```hcl
module "iam_authed_db" {
  source = "..."

  # ... required inputs ...

  iam_database_authentication_enabled = true
}
```

Consumers obtain a connection token via `aws rds
generate-db-auth-token --hostname <cluster_endpoint> --port 5432
--username <iam_user>`. IAM auth composes with the SG ingress gate —
IAM limits *authentication*, the SG limits *reachability*.

## Post-apply smoke recipe

Retrieve the AWS-managed master password from Secrets Manager and
connect via `psql` / `mysql` through a bastion / VPN:

```bash
# Get the secret ARN from module output
SECRET_ARN=$(terraform output -raw master_user_secret_arn)

# Fetch the master user credentials
aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString \
  --output text | jq

# Connect (Postgres example)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text | jq -r .password) \
  psql -h "$CLUSTER_ENDPOINT" -U admin -d postgres
```

## Operational gotchas

### Deletion protection

`deletion_protection = true` by default. To destroy:

1. Flip `deletion_protection = false` in a Terraform PR + apply.
2. THEN run `terraform destroy` (also supply
   `-var 'final_snapshot_identifier=...'` unless
   `skip_final_snapshot = true` — the Q9 precondition rejects
   destroy plans missing both).

### KMS key with `prevent_destroy = true`

The module-managed KMS key carries `lifecycle { prevent_destroy =
true }`. Destroying the cluster doesn't destroy the key — operators
unblock destruction via a deliberate two-step PR:

1. Empty the cluster (no databases hold data).
2. Remove the `lifecycle { prevent_destroy = true }` block in
   `kms.tf` AND any cluster resources still referencing it.
3. Apply + destroy.

This is mostly relevant in dev environments — production clusters
should keep the key indefinitely to avoid losing access to snapshots
encrypted with it.

### Engine-major upgrades

`auto_minor_version_upgrade = true` lets AWS apply engine-minor
upgrades during the maintenance window. Engine-major upgrades
(`14` → `15`, `15` → `16`) are explicit operator PRs bumping
`var.engine_version`. AWS performs the upgrade in-place during the
next maintenance window unless `apply_immediately = true`.

Before bumping a major version:

- Check the parameter family map in `locals.tf` has an entry for the
  new major (Renovate handles this on a slow cadence).
- Verify application compatibility against the new major (especially
  Postgres pgcrypto / extension changes).
- Plan in a non-production environment first.

### Scaling (ACU) changes

Changing `min_acu` / `max_acu` is in-place-apply-safe — Aurora
adjusts the scaling configuration without restarting the cluster.
The precondition `min_acu <= max_acu` is enforced at plan time.

### Final snapshot

`skip_final_snapshot = false` by default. At destroy time, the
caller must supply `-var 'final_snapshot_identifier=...'` or the Q9
precondition fails the plan. Pick a stable identifier (e.g.,
`platform-db-final-20260530`) so the snapshot is findable in the
console / CLI later.

## Tests

```bash
# Plan-only suite (~1.5s, no LocalStack):
just tf test rds/serverless

# Apply-LocalStack suite (gap-discovery — see FINDINGS.md):
just tf test-localstack rds/serverless
```

## Module map

| File | Purpose |
|------|---------|
| `versions.tf` | Provider + Terraform version pins |
| `variables.tf` | Full input contract (25 variables) |
| `main.tf` | `data.terraform_remote_state.vpc` |
| `locals.tf` | Parameter family map, engine port map, KMS ARN coalesce |
| `kms.tf` | Module-managed KMS key + alias (gated BYO) |
| `network.tf` | Subnet group + security group + ingress/egress rules |
| `parameter_groups.tf` | Cluster + instance parameter groups |
| `cluster.tf` | `aws_rds_cluster` (Serverless v2 mode) + 3 preconditions |
| `instance.tf` | `aws_rds_cluster_instance` (`db.serverless`) + 1 precondition |
| `outputs.tf` | 14 consumer-contract outputs |
| `tests/` | Plan-only `terraform test` suite (21 runs) |
| `tests-localstack/` | Gap-discovery apply suite + FINDINGS.md |
