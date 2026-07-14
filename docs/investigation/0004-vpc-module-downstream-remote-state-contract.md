---
id: INV-0004
title: "VPC module downstream remote-state contract"
status: Concluded
author: Donald Gifford
created: 2026-07-14
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0004: VPC module downstream remote-state contract

**Status:** Concluded
**Author:** Donald Gifford
**Date:** 2026-07-14

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [Finding 1 — the consumed contract is exactly two outputs](#finding-1--the-consumed-contract-is-exactly-two-outputs)
  - [Finding 2 — consumer inventory (six modules)](#finding-2--consumer-inventory-six-modules)
  - [Finding 3 — the state-key convention is byte-identical everywhere](#finding-3--the-state-key-convention-is-byte-identical-everywhere)
  - [Finding 4 — multi-AZ private subnets are an implicit hard requirement](#finding-4--multi-az-private-subnets-are-an-implicit-hard-requirement)
  - [Finding 5 — fully Community-LocalStack-testable, no Pro tier](#finding-5--fully-community-localstack-testable-no-pro-tier)
  - [Finding 6 — greenfield: no prior art, established conventions apply](#finding-6--greenfield-no-prior-art-established-conventions-apply)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
  - [Proposed module shape](#proposed-module-shape)
    - [Inputs](#inputs)
    - [Resources](#resources)
    - [Outputs](#outputs)
  - [Proposed test surface](#proposed-test-surface)
  - [Open questions for the DESIGN doc](#open-questions-for-the-design-doc)
  - [Next steps](#next-steps)
- [References](#references)
<!--toc:end-->

## Question

Six in-repo modules read a VPC through S3 remote state, but **no `modules/vpc/`
producer module exists** — the VPC is only ever stood up as throwaway
networking inside each module's `tests-localstack/fixtures/setup/`. What is the
exact **output contract** a first-party VPC module must publish to satisfy those
consumers, and what **module shape** (inputs, resources, state key, tests) does
that contract imply?

## Hypothesis

The *consumed* surface is narrow — probably just `vpc_id` plus a list of private
subnet IDs — so the module's public **contract** is tiny even though its
**internals** (subnets across AZs, IGW, NAT, route tables, CIDR math) are
substantial. Expect the module to be fully Community-LocalStack-testable (pure
EC2/VPC core API), unlike the Pro-gated RDS family.

## Context

The RDS family (DESIGN-0007) and the EKS family (DESIGN-0002) both consume a VPC
they do not own; ADR-0001 uses that very VPC→subnet relationship as its canonical
example of cross-module composition via `terraform_remote_state`. Every one of
those designs *assumes a VPC producer stack exists and publishes subnet IDs* —
but that producer has never been written. This investigation pins the producer
contract down before a DESIGN/IMPL is authored, so the new module's outputs match
what the fleet already reads (renaming a producer output later is a breaking
change to all consumers).

**Triggered by:** request to build a first-party VPC module (this branch,
`inv/vpc-module-downstream-contract`).

## Approach

1. `grep` every `data "terraform_remote_state" "vpc"` block and every
   `terraform_remote_state.vpc.outputs.*` reference across `modules/` (excluding
   `.terraform/`).
2. Read each consumption site to record the output's **shape** and any implicit
   **AZ / multiplicity** requirement.
3. Cross-check ADR-0001 (remote-state convention), the de-facto tagging/naming
   conventions, INV-0001 (module scaffolding), and the test-tier split, so the
   recommendation lands as a drop-in fleet member.

## Environment

| Component | Version / Value |
|-----------|-----------------|
| Terraform | `>= 1.1` (fleet-wide `required_version`) |
| AWS provider | `hashicorp/aws ~> 6.2` |
| State backend | S3, `use_path_style = true` (LocalStack path-style) |
| Modules surveyed | `eks/cluster`, `eks/managed-node-group`, `rds/{serverless,cluster,instance,proxy,read-replica}`, `efs/filesystem` |

## Findings

### Finding 1 — the consumed contract is exactly two outputs

Across the entire `modules/` tree, only two VPC remote-state outputs are ever
read:

| Output | Type | Reference count |
|--------|------|-----------------|
| `private_subnet_ids` | `list(string)` | 7 |
| `vpc_id` | `string` | 5 |

No consumer reads `public_subnet_ids`, `vpc_cidr_block`, `availability_zones`,
NAT gateway IDs, or route-table IDs. The contract the VPC module *must* satisfy
is these two outputs — nothing more. (The `terraform_remote_state.eks.*` and
`terraform_remote_state.target.*` references seen in the grep are different
upstreams — the EKS-cluster stack and the RDS-proxy target stack — not the VPC.)

### Finding 2 — consumer inventory (six modules)

| Consumer module | Output(s) read | How it is used |
|-----------------|----------------|----------------|
| `eks/cluster` | `private_subnet_ids`, `vpc_id` | `aws_eks_cluster.vpc_config.subnet_ids`; `aws_security_group.vpc_id` |
| `eks/managed-node-group` | `private_subnet_ids` | node-group `subnet_ids` |
| `rds/serverless` | `private_subnet_ids`, `vpc_id` | `aws_db_subnet_group.subnet_ids`; DB-tier `aws_security_group.vpc_id` |
| `rds/cluster` | `private_subnet_ids`, `vpc_id` | same as serverless |
| `rds/instance` | `private_subnet_ids`, `vpc_id` | same as serverless |
| `efs/filesystem` | `private_subnet_ids`, `vpc_id` | one `aws_efs_mount_target` **per subnet**; SG `vpc_id` |

`rds/proxy` and `rds/read-replica` are *not* direct VPC consumers — they compose
off another RDS module's remote state (the target/cluster), inheriting the
subnet topology transitively.

### Finding 3 — the state-key convention is byte-identical everywhere

Every VPC remote-state block is identical, confirming ADR-0001's key scheme:

```hcl
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
```

Consequences for the producer:

- The VPC module must write its state to `${region}/vpc/${name}/terraform.tfstate`
  (this key lives in the operator's Terragrunt/backend config, not module HCL).
- Its `name` input is what consumers pass as `vpc_name` — the identifier segment
  of the key.
- All consumers set `use_path_style = true` (a LocalStack S3 detail). ADR-0001's
  prose omits it; the code sets it. The producer's backend must match for
  LocalStack-backed test runs.

### Finding 4 — multi-AZ private subnets are an implicit hard requirement

`private_subnet_ids` is consumed by:

- an **RDS DB subnet group** — AWS requires member subnets in **≥ 2 AZs**;
- an **EKS cluster** `vpc_config` — requires subnets in **≥ 2 AZs**;
- **EFS**, which creates **one mount target per subnet** (so subnets should be
  one-per-AZ to avoid `MountTargetConflict`).

Therefore the VPC module **must** place its private subnets across **≥ 2 AZs**.
A single-subnet (or single-AZ) output would pass `terraform validate` but fail
RDS/EKS *apply*. This is the single most important internal invariant and should
be enforced by an input validation (`az_count >= 2`).

### Finding 5 — fully Community-LocalStack-testable, no Pro tier

Every resource a VPC module needs — `aws_vpc`, `aws_subnet`,
`aws_internet_gateway`, `aws_eip`, `aws_nat_gateway`, `aws_route_table`,
`aws_route_table_association` — is core EC2/VPC API and supported by **Community
LocalStack**. Unlike the RDS Pro family (embedded Postgres, named-volume
`initdb` workaround, `tests-localstack-pro/`), the VPC module gets a **real
apply suite in `tests-localstack/`** with no Pro token and no macOS volume
gymnastics. The throwaway networking already duplicated across ~6
`tests-localstack/fixtures/setup/` directories is essentially this module — it
can be promoted into the real module and dogfooded by those fixtures.

### Finding 6 — greenfield: no prior art, established conventions apply

There is **no** `modules/vpc/`, and **no** networking ADR/RFC/DESIGN. The only
`aws_vpc`/`aws_subnet` definitions in-repo are throwaway test fixtures. The
fleet's de-facto conventions the new module must adopt:

- **Tagging:** a `variable "tags" { type = map(string); default = {} }`, applied
  as `merge(var.tags, { Name = "<per-resource>" })`. The broader tag set
  (Environment, ManagedBy, …) is derived upstream in Terragrunt, per ADR-0001.
- **Naming:** an `identifier_prefix` (or `name`) validated against
  `^[a-z][a-z0-9-]{0,62}[a-z0-9]$`, with resource names as `"${name}-<suffix>"`.
- **Scaffolding (INV-0001):** `versions.tf` (`>= 1.1`, `aws ~> 6.2`),
  `variables.tf`, `outputs.tf`, `main.tf` (+ optional `locals.tf`, `network.tf`),
  `.tflint.hcl`, `.terraform-docs.yml`, `USAGE.md` (with
  `<!-- BEGIN_TF_DOCS -->` markers), `README.md`, `tests/`, `tests-localstack/`.
  Cleanest template to copy: `modules/efs/filesystem/`.

## Conclusion

**Answer:** The VPC module's downstream contract is exactly two stable outputs —
`vpc_id` (`string`) and `private_subnet_ids` (`list(string)` spanning **≥ 2
AZs**) — published at state key `${region}/vpc/${name}/terraform.tfstate`. That
is the *entire* hard requirement imposed by the six current consumers
(`eks/cluster`, `eks/managed-node-group`, `rds/{serverless,cluster,instance}`,
`efs/filesystem`).

Everything else the module builds — public subnets, IGW, NAT, route tables, CIDR
allocation — is internal plumbing needed to produce those two outputs correctly.
Any additional outputs are additive future-proofing, not required by an existing
consumer. The module is greenfield and fully Community-LocalStack-testable.

## Recommendation

Proceed to a DESIGN doc for a first-party VPC module. Proposed location:
**`modules/vpc/network/`** — the `vpc/` service segment matches the state-key
convention and leaves room for siblings (`modules/vpc/{peering,endpoints,tgw-attachment}`).

### Proposed module shape

#### Inputs

| Input | Type | Default | Notes |
|-------|------|---------|-------|
| `name` | `string` | — | Maps to consumers' `vpc_name`; identifier segment of the state key. Validate `^[a-z][a-z0-9-]{0,62}[a-z0-9]$`. |
| `region` | `string` | — | AWS region; also the leading state-key segment. |
| `cidr_block` | `string` | — | VPC CIDR. Validate it parses as a CIDR. |
| `az_count` | `number` | `2` | **Validate `>= 2`** (Finding 4). Precondition: `<=` region AZ count via `data.aws_availability_zones`. |
| `enable_nat_gateway` | `bool` | `true` | Private-subnet egress. |
| `single_nat_gateway` | `bool` | `true` | One shared NAT (cost) vs one-per-AZ (HA). |
| `enable_dns_hostnames` / `enable_dns_support` | `bool` | `true` | Required for EKS + private DNS. |
| `map_public_ip_on_launch` | `bool` | `false` | Public-subnet auto-assign. |
| `tags` | `map(string)` | `{}` | `merge(var.tags, { Name = … })` per resource. |

#### Resources

`aws_vpc`, `aws_subnet` (one public + one private per AZ),
`aws_internet_gateway`, `aws_eip` + `aws_nat_gateway`, `aws_route_table`
(public + private) + `aws_route_table_association`,
`data.aws_availability_zones`. Prefer `for_each` over `count` for subnets.

#### Outputs

- **Contract (stable — never rename):** `vpc_id`, `private_subnet_ids`.
- **Additive (recommended):** `public_subnet_ids`, `vpc_cidr_block`,
  `availability_zones`, `nat_gateway_ids`, `private_route_table_ids`, `igw_id`.

### Proposed test surface

- **`tests/`** (plan-only gate, the primary CI gate): `cidr_block` validation
  negatives, `az_count >= 2` negative, subnet count == `az_count`, contract-output
  presence.
- **`tests-localstack/`** (Community apply): real VPC/subnets/NAT; assert
  `private_subnet_ids` spans **≥ 2 distinct AZs**; assert contract outputs
  non-empty; `fixtures/` if any upstream is needed (none expected — VPC is a
  root producer).
- **No `tests-localstack-pro/`** (Finding 5).

### Open questions for the DESIGN doc

1. **Component name:** `modules/vpc/network` (recommended) vs `modules/vpc/vpc`.
2. **NAT default:** single shared NAT (recommended default — cost) vs one-per-AZ.
3. **AZ-count default:** `2` (contract minimum, recommended) vs `3`.
4. **Publish `public_subnet_ids` now?** No consumer reads it yet; recommend
   emitting anyway (additive — future ALB/ingress modules will want it).
5. **Dogfood:** should this module *replace* the throwaway networking duplicated
   across the ~6 `tests-localstack/fixtures/setup/` dirs (dedup + real coverage)?

### Next steps

1. `docz create design "VPC network module"` — finalize the open questions above.
2. `docz create impl "VPC network module"` — phased build (versions/vars →
   VPC+subnets → IGW/NAT/routes → outputs → tests/ → tests-localstack/).
3. Copy `modules/efs/filesystem/` scaffolding as the starting template.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state` (state-key
  convention, producer/consumer wiring).
- DESIGN-0002 (EKS cluster), DESIGN-0007 (RDS family), DESIGN-0008 (EFS) —
  consumers that assume this VPC producer.
- INV-0001 — Module scaffolding, distribution, and presence-check CI.
- RFC-0001 / ADR-0013 / ADR-0014 — module testing strategy (tier split).
- `modules/efs/filesystem/` — cleanest simple-module template.
