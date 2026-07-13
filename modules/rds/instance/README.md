<!-- markdownlint-disable-file MD025 MD041 -->
# RDS Instance Module

Provisions a single, non-clustered `aws_db_instance` (Postgres or MySQL) with
module-managed KMS encryption, an AWS-managed master password via Secrets
Manager, opt-in IAM database authentication, and the non-Aurora storage surface
(`allocated_storage`, storage autoscaling, `storage_type`, `iops`, `multi_az`).
Network composition flows through `data.terraform_remote_state.vpc` (S3 backend,
same convention as the EKS + Aurora modules).

For Aurora workloads use `modules/rds/serverless` (Serverless v2) or
`modules/rds/cluster` (provisioned) instead. This module is a valid RDS Proxy
target — set `target_type = "rds-instance"` on `modules/rds/proxy`.

Implements
[IMPL-0011](../../../docs/impl/0011-rds-instance-module-implementation.md)
/ [DESIGN-0012](../../../docs/design/0012-rds-instance-module-single-awsdbinstance.md)
/ the `instance` slot of
[DESIGN-0007](../../../docs/design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Prerequisites

1. **VPC stack landed first** — applied to the same AWS account + region as the
   instance, with state written to S3 at
   `<region>/vpc/<vpc_name>/terraform.tfstate`. Required outputs in the state
   file: `vpc_id`, `private_subnet_ids` (per IMPL-0007 Q1 — reuses the
   EKS-cluster remote-state contract). The subnets must span at least two
   availability zones (the DB subnet group requirement).
2. **S3 backend bucket** exists and is reachable from the runner applying this
   module.
3. **LocalStack** — optional, for the test suites. The default
   `just tf test-localstack rds/instance` runs a Community-safe `plan_smoke`
   (offline-safe). The real apply is Pro-gated in `tests-localstack-pro/` (off
   by default) — see [`tests-localstack/FINDINGS.md`](tests-localstack/FINDINGS.md).

## Instantiation

### Minimal Postgres example

```hcl
module "platform_db" {
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/rds/instance?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "platform-db"

  engine            = "postgres"
  instance_class    = "db.t4g.medium"
  allocated_storage = 50

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
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/rds/instance?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  identifier_prefix   = "analytics-db"

  engine            = "mysql"
  instance_class    = "db.t4g.medium"
  allocated_storage = 20

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

  engine            = "postgres"
  instance_class    = "db.r6g.large"
  allocated_storage = 100
  kms_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/abc-def-ghi"
}
```

When `kms_key_arn` is set, the module skips its internal key + alias. The same
caller-supplied key encrypts both instance storage at rest and the master user
secret (per IMPL-0007 Q12).

### Storage autoscaling

```hcl
module "growing_db" {
  source = "..."

  # ... required inputs ...

  allocated_storage     = 50  # starting floor
  max_allocated_storage = 500 # autoscaling ceiling
}
```

Setting `max_allocated_storage` (default `null` = off) enables RDS storage
autoscaling up to the ceiling. The module adds **no** `lifecycle.ignore_changes`
— the AWS provider suppresses the `allocated_storage` diff for autoscaling-driven
growth, and deliberate manual resizes (bumping `var.allocated_storage`) still
apply (DESIGN-0012 Q3). `max_allocated_storage` must be `>= allocated_storage`
(plan-time precondition).

### Provisioned IOPS (io2)

```hcl
module "high_io_db" {
  source = "..."

  # ... required inputs ...

  storage_type = "io2"
  iops         = 3000 # required when storage_type = "io2" (precondition)
}
```

### Opt-in IAM database authentication

```hcl
module "iam_authed_db" {
  source = "..."

  # ... required inputs ...

  iam_database_authentication_enabled = true
}
```

Consumers obtain a connection token via `aws rds generate-db-auth-token
--hostname <endpoint> --port 5432 --username <iam_user>`. IAM auth composes with
the SG ingress gate — IAM limits *authentication*, the SG limits *reachability*.

## Post-apply smoke recipe

Retrieve the AWS-managed master password from Secrets Manager and connect via
`psql` / `mysql` through a bastion / VPN:

```bash
# Get the secret ARN from module output
SECRET_ARN=$(terraform output -raw master_user_secret_arn)

# Fetch the master user credentials
aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString \
  --output text | jq

# Connect (Postgres example)
ADDRESS=$(terraform output -raw address)
PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text | jq -r .password) \
  psql -h "$ADDRESS" -U admin -d postgres
```

## Operational gotchas

### Deletion protection

`deletion_protection = true` by default. To destroy:

1. Flip `deletion_protection = false` in a Terraform PR + apply.
2. THEN run `terraform destroy` (also supply
   `-var 'final_snapshot_identifier=...'` unless `skip_final_snapshot = true` —
   the precondition rejects destroy plans missing both).

### KMS key with `prevent_destroy = true`

The module-managed KMS key carries `lifecycle { prevent_destroy = true }`.
Destroying the instance doesn't destroy the key — operators unblock destruction
via a deliberate two-step PR:

1. Confirm no snapshots you still need are encrypted with the key.
2. Remove the `lifecycle { prevent_destroy = true }` block in `kms.tf` AND any
   resources still referencing it.
3. Apply + destroy.

This is mostly relevant in dev environments — production instances should keep
the key indefinitely to avoid losing access to snapshots encrypted with it.

### Engine-major upgrades

`auto_minor_version_upgrade = true` lets AWS apply engine-minor upgrades during
the maintenance window. Engine-**major** upgrades (`16` → `17`, `8.0` → `8.4`)
are explicit operator PRs bumping `var.engine_version`. Note v1 does **not**
expose `allow_major_version_upgrade`, so a cross-major bump requires adding that
argument first (a small additive change) plus a matching `var.parameter_family`
/ family-map entry. Plan the upgrade in a non-production environment first
(especially Postgres extension changes).

Changing `var.engine` itself (e.g. `postgres` → `mysql`) forces instance
replacement — that is a new database, not an upgrade.

### Storage autoscaling and manual resizes

With `max_allocated_storage` set, AWS grows `allocated_storage` automatically up
to the ceiling; the provider suppresses that drift, so no perpetual diff appears
(DESIGN-0012 Q3, no `ignore_changes`). A deliberate resize — bumping
`var.allocated_storage` — still applies in-place. Shrinking storage is not
supported by RDS (a snapshot-restore is required).

### Multi-AZ

`multi_az = false` by default (single-AZ; matches the cost posture). Set
`multi_az = true` for a synchronous standby in a second AZ — roughly doubles
instance cost, applied in-place.

### Final snapshot

`skip_final_snapshot = false` by default. At destroy time, the caller must
supply `-var 'final_snapshot_identifier=...'` or the precondition fails the plan.
Pick a stable identifier (e.g., `platform-db-final-20260712`) so the snapshot is
findable later.

## Tests

```bash
# Plan-only suite (~2.6s, no LocalStack):
just tf test rds/instance

# Community-safe plan_smoke (offline-safe):
just tf test-localstack rds/instance

# Pro apply suite (off by default; needs LocalStack Pro on :4566):
just tf test-localstack-pro rds/instance
```

## Module map

| File | Purpose |
|------|---------|
| `versions.tf` | Provider + Terraform version pins |
| `variables.tf` | Full input contract (35 variables) |
| `main.tf` | `data.terraform_remote_state.vpc` |
| `locals.tf` | Parameter family map, engine port map, resolved port, KMS ARN coalesce |
| `kms.tf` | Module-managed KMS key + alias (gated BYO) |
| `network.tf` | Subnet group + security group + ingress/egress rules |
| `parameter_groups.tf` | Single `aws_db_parameter_group` |
| `instance.tf` | `aws_db_instance` + storage surface + 5 preconditions |
| `outputs.tf` | Instance contract + 7 proxy-composition outputs |
| `tests/` | Plan-only `terraform test` suite (26 runs) |
| `tests-localstack/` | Community `plan_smoke` + FINDINGS.md |
| `tests-localstack-pro/` | Pro apply suite (off by default) |
