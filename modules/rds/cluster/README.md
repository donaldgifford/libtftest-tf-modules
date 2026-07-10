<!-- markdownlint-disable-file MD025 MD041 -->
# Aurora Provisioned Cluster Module

Provisions an Aurora **provisioned** cluster (Postgres or MySQL) with a
single writer instance of a concrete `instance_class` (e.g.
`db.r6g.large`), module-managed KMS encryption, AWS-managed master
password via Secrets Manager, and opt-in IAM database authentication.
Network composition flows through `data.terraform_remote_state.vpc`
(S3 backend, same convention as the EKS modules).

This is the `serverless` module with two edits: no
`serverlessv2_scaling_configuration` block (and no `min_acu`/`max_acu`
inputs), and a concrete `var.instance_class` in place of the
`db.serverless` sentinel. It is the **source-of-truth remote state** for
the cluster ↔ `read-replica` composition (IMPL-0013) and a valid RDS
Proxy target (`target_type = "aurora-cluster"`).

Implements
[IMPL-0012](../../../docs/impl/0012-rds-aurora-provisioned-cluster-module-implementation.md)
/ [DESIGN-0013](../../../docs/design/0013-rds-aurora-provisioned-cluster-module.md).

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
3. **LocalStack** — optional. A provisioned cluster instance boots a
   real embedded PostgreSQL, so the full apply is **Pro-gated**
   (`tests-localstack-pro/`, off by default); the always-on
   `tests-localstack/` suite is a Community-safe `plan_smoke`. See
   [`tests-localstack/FINDINGS.md`](tests-localstack/FINDINGS.md).

## Instantiation

### Minimal Postgres example

```hcl
module "platform_db" {
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/rds/cluster?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "platform-db"

  engine         = "aurora-postgresql"
  instance_class = "db.r6g.large"

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
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/rds/cluster?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "analytics-db"

  engine         = "aurora-mysql"
  instance_class = "db.t4g.medium"

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

  engine         = "aurora-postgresql"
  instance_class = "db.r6g.xlarge"
  kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/abc-def-ghi"
}
```

When `kms_key_arn` is set, the module skips its internal key + alias.
The same caller-supplied key encrypts both cluster storage at rest and
the master user secret (per IMPL-0007 Q12).

### I/O-Optimized storage

```hcl
module "high_io_db" {
  source = "..."

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "high-io-db"

  engine         = "aurora-postgresql"
  instance_class = "db.r6g.2xlarge"
  storage_type   = "aurora-iopt1"
}
```

`storage_type = "aurora-iopt1"` is Aurora I/O-Optimized: no per-request
I/O charges (~30% higher instance/storage rate) — worth it for
cost-conscious high-I/O clusters. Leave `storage_type` null (default)
or set `"aurora"` for Aurora Standard (DESIGN-0013 Q3).

### Opt-in IAM database authentication

```hcl
module "iam_authed_db" {
  source = "..."

  # ... required inputs (engine + instance_class) ...

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

## Scaling out — read replicas

This module provisions exactly one writer. To add readers, land the
`read-replica` module (IMPL-0013) alongside it: that module composes via
**this cluster's remote state**, reading `cluster_identifier`,
`cluster_resource_id`, `engine`, `engine_version_actual`,
`db_subnet_group_name`, and `db_parameter_group_name` from the S3 state
at:

```text
<region>/rds/cluster/<identifier_prefix>/terraform.tfstate
```

Readers attach to this cluster and default to `promotion_tier = 15` so
they never outrank the writer (`promotion_tier = 0`) during failover
(DESIGN-0013 Q1 / DESIGN-0014 Q2). Do not scale reads by resizing the
writer — add readers.

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

### Resizing the writer

Changing `instance_class` (e.g. `db.r6g.large` → `db.r6g.xlarge`) is an
in-place modification that reboots the writer instance. AWS applies it
during the next maintenance window unless `apply_immediately = true`
(which triggers an immediate reboot — expect a brief connection drop).
For read-heavy scaling, add readers via the `read-replica` module rather
than resizing the writer.

### Aurora Backtrack is MySQL-only

`backtrack_window > 0` (Aurora fast-rewind) is enforced Aurora-**MySQL**
-only by a cluster precondition — it is rejected for `aurora-postgresql`.
Leave `backtrack_window = 0` (default) unless you are on `aurora-mysql`
and want point-in-time rewind (DESIGN-0013 Q4).

### Final snapshot

`skip_final_snapshot = false` by default. At destroy time, the
caller must supply `-var 'final_snapshot_identifier=...'` or the Q9
precondition fails the plan. Pick a stable identifier (e.g.,
`platform-db-final-20260710`) so the snapshot is findable in the
console / CLI later.

## Tests

```bash
# Plan-only suite (~5s, no LocalStack):
just tf test rds/cluster

# Community plan_smoke (offline-safe, plan-only):
just tf test-localstack rds/cluster

# Pro apply suite (opt-in — needs LocalStack Pro; see FINDINGS.md):
just tf test-localstack-pro rds/cluster
```

## Module map

| File | Purpose |
|------|---------|
| `versions.tf` | Provider + Terraform version pins |
| `variables.tf` | Full input contract (no `min_acu`/`max_acu`; + `instance_class`, `storage_type`, `backtrack_window`, `enabled_cloudwatch_logs_exports`, `promotion_tier`) |
| `main.tf` | `data.terraform_remote_state.vpc` |
| `locals.tf` | Parameter family map, engine port map, KMS ARN coalesce |
| `kms.tf` | Module-managed KMS key + alias (gated BYO) |
| `network.tf` | Subnet group + security group + ingress/egress rules |
| `parameter_groups.tf` | Cluster + instance parameter groups |
| `cluster.tf` | `aws_rds_cluster` (`provisioned`, no scaling block) + 3 preconditions |
| `instance.tf` | `aws_rds_cluster_instance.writer` (concrete `instance_class`) + 1 precondition |
| `outputs.tf` | 14 consumer-contract + 4 proxy-composition outputs |
| `tests/` | Plan-only `terraform test` suite (19 runs) |
| `tests-localstack/` | Community `plan_smoke` + FINDINGS.md |
| `tests-localstack-pro/` | Pro-gated apply suite + setup fixture |
