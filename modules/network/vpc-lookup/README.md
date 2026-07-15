<!-- markdownlint-disable-file MD025 MD041 -->
# VPC Lookup Module (read-only)

Read-only discovery of an **existing** VPC. This module manages **no** AWS
resources — it looks a VPC and its subnets / gateways / route tables up via
`data` sources and re-publishes the downstream remote-state contract
(`vpc_id`, `private_subnet_ids`) plus additive network facts, so the
`rds/*`, `eks/*`, and `efs/*` modules can consume a network Terraform does
not own.

It is the "never let Terraform own the network" companion to the
create-or-adopt `modules/network/vpc` proposed in
[INV-0004](../../../docs/investigation/0004-vpc-module-downstream-remote-state-contract.md),
and it lands **first** as a stand-in to exercise the remote-state
consumption contract before the full VPC module is built.

See [USAGE.md](USAGE.md) for the generated input / output reference.

## What it discovers

| Output | Source | Consumer |
|--------|--------|----------|
| `vpc_id` | `data.aws_vpc` | **contract** — RDS/EKS/EFS security groups |
| `private_subnet_ids` | `data.aws_subnets` (`Network=Private`) | **contract** — RDS subnet groups, EFS mount targets, EKS worker nodes |
| `private_eks_subnet_ids` | `data.aws_subnets` (`Network=Private EKS`) | EKS `vpc_config.subnet_ids` (internal cluster IP range) |
| `public_subnet_ids` | `data.aws_subnets` (`Network=Public`) | additive |
| `vpc_cidr_block` | `data.aws_vpc` | additive |
| `availability_zones` | `data.aws_subnet` (per private subnet) | additive |
| `nat_gateway_ids` | `data.aws_nat_gateways` | additive |
| `route_table_ids` | `data.aws_route_tables` | additive |
| `internet_gateway_id` | `data.aws_internet_gateway` | additive |

Only `vpc_id` + `private_subnet_ids` are the stable contract (INV-0004
Finding 1); the rest are additive and may be renamed before a 1.0 tag.

## Subnet topology

The module expects a **three-tier** subnet layout, discriminated by a
`Network` tag (each tier spanning ≥ 2 AZs):

| Tier | `Network` tag | passive k8s role tag | Purpose |
|------|---------------|----------------------|---------|
| Public | `Public` | `kubernetes.io/role/elb = 1` | internet-facing load balancers |
| Private | `Private` | `kubernetes.io/role/internal-elb = 1` | data tier (RDS/EFS) + EKS worker nodes + internal LBs |
| Private EKS | `Private EKS` | — | internal EKS cluster IP range (control-plane ENIs) |

The `kubernetes.io/role/*` tags are **passive** — the AWS Load Balancer
Controller auto-discovers subnets by them at runtime, so the module only
needs them to exist on the subnets; discovery filters on the `Network`
tag (which uniquely identifies all three tiers).

## Discovery

By default the module finds the VPC by `tag:Name = var.name`, and its
three subnet tiers by their `Network` tags:

```hcl
module "vpc" {
  source = "../../network/vpc-lookup"
  name   = "platform-prod" # matches the VPC's Name tag
}
```

Pin an explicit VPC when the `Name` tag is ambiguous:

```hcl
module "vpc" {
  source = "../../network/vpc-lookup"
  name   = "platform-prod"
  vpc_id = "vpc-0abc123def4567890"
}
```

Override the tier tag conventions if your VPC uses a different scheme:

```hcl
module "vpc" {
  source                  = "../../network/vpc-lookup"
  name                    = "platform-prod"
  private_subnet_tags     = { Network = "Private" }
  public_subnet_tags      = { Network = "Public" }
  private_eks_subnet_tags = { Network = "Private EKS" }
}
```

## Publishing remote state for consumers

Apply this module with an S3 backend keyed at the convention every
consumer already reads — `<region>/vpc/<name>/terraform.tfstate`:

```hcl
# backend config (Terragrunt-generated in the live layer)
terraform {
  backend "s3" {
    bucket         = "your-org-tfstate"
    key            = "us-east-1/vpc/platform-prod/terraform.tfstate"
    region         = "us-east-1"
    use_path_style = true # LocalStack; drop for real S3
  }
}
```

The RDS / EKS / EFS modules then resolve `vpc_id` + `private_subnet_ids`
from that key with **no change on their side** — they already read
`data.terraform_remote_state.vpc` at exactly this key.

## Tests

```bash
# Plan-only suite (mock provider, no LocalStack, ~1s):
just tf test network/vpc-lookup

# Apply against a real fixtured VPC in LocalStack Community (~30s):
just tf test-localstack network/vpc-lookup
```

The LocalStack suite is **Community-safe** — pure EC2/VPC API, no Pro
tier, no auth token, no named-volume workaround. See
[tests-localstack/FINDINGS.md](tests-localstack/FINDINGS.md).

## Module map

| File | Purpose |
|------|---------|
| `versions.tf` | Provider + Terraform version pins |
| `variables.tf` | Discovery inputs (`name`, `vpc_id`, per-tier tag filters, IGW toggle) |
| `main.tf` | `data.aws_vpc` / `aws_subnets` ×3 tiers / `aws_subnet` / `aws_nat_gateways` / `aws_route_tables` / `aws_internet_gateway` |
| `locals.tf` | Tag composition, sorted subnet lists, AZ extraction |
| `outputs.tf` | 2 contract + 7 additive outputs (incl. `private_eks_subnet_ids`) |
| `tests/` | Plan-only mock-provider suite (2 runs) |
| `tests-localstack/` | Apply against a fixtured LocalStack VPC (3 runs) + FINDINGS.md |
