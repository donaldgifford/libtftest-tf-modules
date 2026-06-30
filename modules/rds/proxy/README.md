<!-- markdownlint-disable-file MD025 MD041 -->
# RDS Proxy Module

Places an Amazon RDS Proxy in front of an RDS or Aurora data-tier module —
connection pooling, a stable endpoint across failovers, and IAM-token auth,
without the application managing any of it. A single module serves
`rds-instance`, `aurora-cluster`, and `serverless` targets via
`var.target_type`; the resource graph is identical bar one attribute on the
proxy target.

Composition flows through `data.terraform_remote_state` (S3 backend, the
fleet's ADR-0001 convention): the proxy reads the target DB module's outputs —
master secret ARN, security group, subnet IDs, VPC, secret CMK, engine, and the
instance/cluster identifier — keyed on `var.target_type` +
`var.target_identifier`. Nothing the target already owns is re-declared here.

Both engine families are supported: PostgreSQL (`postgres`,
`aurora-postgresql`, port 5432) and MySQL (`mysql`, `aurora-mysql`, port 3306).
The `engine_family` and listener port derive from the target's `engine` read
from remote state, so the proxy can never drift from its target. SQL Server and
MariaDB are out of scope (DESIGN-0010 Non-Goals).

Implements
[IMPL-0010](../../../docs/impl/0010-rds-proxy-module-implementation.md)
/ [DESIGN-0010](../../../docs/design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Prerequisites

1. **A data-tier target applied first**, with its state in S3 at the
   conventional key `<region>/rds/<dir>/<target_identifier>/terraform.tfstate`
   (`<dir>` = `instance` | `cluster` | `serverless`). Today the
   [`serverless`](../serverless) module is the live target; it emits the
   proxy-composition outputs (`db_subnet_ids`, `vpc_id`,
   `master_user_secret_arn`, `master_user_secret_kms_key_arn`,
   `security_group_id`, `engine`, `iam_database_authentication_enabled`).
2. **An AWS-managed master secret** on the target
   (`manage_master_user_password = true`, the serverless default) — the proxy
   reuses it; no new secret is minted.
3. The proxy lives in the **same VPC and subnets** as the target, is
   **non-public**, and uses **no dedicated tenancy** (RDS Proxy constraints).

## Quickstart

Proxy in front of a `serverless` Postgres cluster:

```hcl
module "db_proxy" {
  source = "../../modules/rds/proxy"

  region              = "us-east-1"
  name                = "platform-proxy"
  remote_state_bucket = "my-org-terraform-state"
  target_type         = "serverless"
  target_identifier   = "platform-rds" # the serverless cluster's identifier_prefix

  # Who may reach the proxy (clients → proxy on the engine port):
  allowed_consumer_sg_ids = [module.app.security_group_id]

  # Optional: an Aurora reader endpoint for read traffic.
  create_read_only_endpoint = true

  tags = { Environment = "prod" }
}
```

Then, on a subsequent apply, admit the proxy at the DB tier by passing its SG
into the target module's consumer list (see **Security-group wiring**).

## Usage notes

### `target_type`

| `target_type`    | Reads state key segment | Proxy target attribute   |
|------------------|-------------------------|--------------------------|
| `rds-instance`   | `instance`              | `db_instance_identifier` |
| `aurora-cluster` | `cluster`               | `db_cluster_identifier`  |
| `serverless`     | `serverless`            | `db_cluster_identifier`  |

The proxy attaches to the **writer**. RDS instances have no proxy reader
routing, so `create_read_only_endpoint` is rejected for `rds-instance` (a
plan-time precondition, V3). Aurora targets get an optional separate
`READ_ONLY` endpoint for reads.

### Secret reuse

The proxy's `auth.secret_arn` is the target's `master_user_secret_arn` straight
from remote state — no new secret. The module-managed IAM role gets
least-privilege `secretsmanager:GetSecretValue` on exactly that ARN and
`kms:Decrypt` on the secret's CMK.

### Client auth

`require_iam_auth = true` maps to `auth.iam_auth = REQUIRED`; clients then get a
token via `aws rds generate-db-auth-token` against the **proxy** endpoint. This
requires the target to have `iam_database_authentication_enabled = true` — a
precondition (V4) enforces it.

### Security-group wiring

The proxy owns its SG: ingress from `allowed_consumer_sg_ids` on the engine
port, egress to the target DB's SG on the engine port. The **reciprocal**
DB-side ingress is not wired here (it would be a cross-module cycle). Complete
it by passing this module's `proxy_security_group_id` output into the target DB
module's `allowed_consumer_sg_ids` on a subsequent apply:

```hcl
module "serverless" {
  source = "../../modules/rds/serverless"
  # ...
  allowed_consumer_sg_ids = [module.db_proxy.proxy_security_group_id]
}
```

## ⚠️ Serverless v2 cost caveat

Attaching an RDS Proxy to an Aurora **Serverless v2** cluster has two cost
implications:

- **8-ACU billing floor.** Proxy usage against Serverless v2 bills a
  `Proxy-ASv2-Usage` line at a minimum of 8 ACUs while the proxy is attached,
  independent of your `min_capacity`.
- **Auto-pause blocked.** An attached proxy holds connections, so the cluster
  cannot scale to zero ACUs / auto-pause.

Budget for the floor before fronting a low-traffic Serverless v2 cluster with a
proxy. For genuinely idle clusters, consider connecting directly.

## Operational gotchas

- **Apply order.** Target first (so its state exists), then the proxy. The
  SG reciprocal is a second apply on the target.
- **TLS on by default** (`require_tls = true`). Clients must connect to the
  proxy endpoint over TLS.
- **One proxy → one target.** A proxy fronts a single writer; it is not a
  fan-in across clusters.
- **Pinning.** Some session state pins a client to a backend connection,
  reducing pool efficiency. Relax with
  `session_pinning_filters = ["EXCLUDE_VARIABLE_SETS"]` where safe.

## Tests

- **Plan-only (the gate):** `just tf test rds/proxy` — all V1–V7 validations,
  engine/identifier routing, pool config, IAM-auth mapping, read-only gating,
  for both engine families. No AWS, ~seconds.
- **LocalStack Pro apply (opt-in):** `just tf test-localstack-pro rds/proxy` —
  applies a real proxy against a LocalStack **Pro** container (RDS Proxy is
  Pro-only). Off by default; see [tests-localstack/FINDINGS.md](tests-localstack/FINDINGS.md).
- **Default LocalStack:** `just tf test-localstack rds/proxy` runs only the
  Community-safe `plan_smoke`.

## Module map

| File | Purpose |
|------|---------|
| `main.tf` | entrypoint + `data.terraform_remote_state.target` |
| `locals.tf` | engine→family/port maps, remote-state output aliases, identifier routing |
| `variables.tf` | pointer + knob input surface + V1/V6/V7 validations |
| `iam.tf` | proxy IAM role + secret/KMS least-privilege policy |
| `security_group.tf` | proxy SG (ingress from consumers, egress to DB) |
| `proxy.tf` | `aws_db_proxy` + target group + target + read-only endpoint + V2–V6 preconditions |
| `outputs.tf` | consumer contract (endpoints, SG id, role ARN) |
| `tests/` | plan-only validation suite |
| `tests-localstack/` | Community-safe `plan_smoke` + FINDINGS |
| `tests-localstack-pro/` | opt-in Pro apply suite + `fixtures/db` |
