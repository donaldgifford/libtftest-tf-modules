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
  - [Finding 6 — no in-repo prior art; established conventions apply](#finding-6--no-in-repo-prior-art-established-conventions-apply)
  - [Finding 7 — brownfield-first: the module must adopt an existing VPC via import](#finding-7--brownfield-first-the-module-must-adopt-an-existing-vpc-via-import)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
  - [Proposed module shape](#proposed-module-shape)
    - [Inputs](#inputs)
    - [Resources](#resources)
    - [Outputs](#outputs)
  - [Proposed test surface](#proposed-test-surface)
  - [Resolved (owner input, 2026-07-14)](#resolved-owner-input-2026-07-14)
  - [Open questions for the DESIGN doc](#open-questions-for-the-design-doc)
  - [Next steps](#next-steps)
- [References](#references)
<!--toc:end-->

## Question

Six in-repo modules read a VPC through S3 remote state, but **no VPC producer
module exists** — the VPC is only ever stood up as throwaway networking inside
each module's `tests-localstack/fixtures/setup/`. What is the exact **output
contract** a first-party VPC module must publish to satisfy those consumers, and
what **module shape** (inputs, resources, state key, tests) does that contract
imply?

A second, load-bearing constraint (per the module owner): in the real fleet a
`network/vpc` **already exists** — created by a landing-zone/account-factory,
click-ops, or legacy Terraform. So the module cannot be create-only; it must be
able to **adopt an existing VPC via import** and then publish its remote state
for the downstream consumers. Greenfield create is the secondary path.

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

### Finding 6 — no in-repo prior art; established conventions apply

There is **no** VPC module, and **no** networking ADR/RFC/DESIGN. The only
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

### Finding 7 — brownfield-first: the module must adopt an existing VPC via import

The operating assumption is that a `network/vpc` **already exists** and is not
currently in this repo's Terraform state. So the module's *primary* job is
**adoption**: bring the existing VPC, subnets, IGW, NAT gateway(s), and route
tables under management (via `terraform import` / config-driven `import {}`
blocks) and then publish the two-output contract to remote state. Greenfield
create is the secondary path (same resource config, no import).

Two design consequences fall out of "must import cleanly":

- **Import must yield a zero-diff plan.** After import, the resource config has
  to reproduce the *existing* VPC's attributes exactly (CIDR, per-subnet CIDRs,
  AZ placement, NAT/route topology, tags). A purely parametric layout (compute
  every subnet CIDR with `cidrsubnet()`) will mismatch any VPC that wasn't laid
  out by that exact formula → a perpetual diff or a destroy/recreate. This
  favors **explicit per-AZ subnet CIDR inputs** (a `map`/`object`) over computed
  CIDR math, with `cidrsubnet()` available only as a default *generator* for the
  greenfield path.
- **Resource addresses must be stable and predictable.** Import targets a
  specific address, so subnets/route-tables should use **`for_each` keyed by AZ**
  (`aws_subnet.private["us-east-1a"]`) — never `count` (index-based
  `[0]` addresses shift and are hostile to import).

**Version implication.** Config-driven `import {}` blocks require Terraform
`>= 1.5`, but the fleet pins `required_version = ">= 1.1"`. Preferred resolution:
keep the *reusable* module at `>= 1.1` with import-friendly addressing + a
documented import runbook, and let the operator's live/Terragrunt layer (which
can require `>= 1.5`) hold the `import {}` blocks that point at
`module.vpc.aws_vpc.this` etc. `terraform import` (CLI) is the `< 1.5` fallback.

## Conclusion

**Answer (contract):** The VPC module's downstream contract is exactly two stable
outputs — `vpc_id` (`string`) and `private_subnet_ids` (`list(string)` spanning
**≥ 2 AZs**) — published at state key `${region}/vpc/${name}/terraform.tfstate`.
That is the *entire* hard requirement imposed by the six current consumers
(`eks/cluster`, `eks/managed-node-group`, `rds/{serverless,cluster,instance}`,
`efs/filesystem`).

**Answer (shape):** Everything else the module builds — public subnets, IGW, NAT,
route tables, CIDR allocation — is internal plumbing needed to produce those two
outputs correctly. The module must be **create-or-adopt** (brownfield import is
the primary path, Finding 7), which pushes the design toward explicit per-AZ
subnet CIDR inputs and `for_each`-by-AZ addressing so an existing VPC imports to
a zero-diff plan. It is fully Community-LocalStack-testable (Finding 5).

## Recommendation

Proceed to a DESIGN doc for a first-party VPC module.

**Location (owner-directed): `modules/network/vpc/`** — a `network` service
directory with a `vpc` component, leaving room for siblings
(`modules/network/{tgw,peering,endpoints}`).

> **Path vs. state key are independent.** The module *source* lives at
> `modules/network/vpc/`, but its *published state key* stays
> `${region}/vpc/${name}/terraform.tfstate` — because all six consumers already
> hardcode `key = "${region}/vpc/${vpc_name}/..."`. Changing the key segment
> would force an edit to every consumer, so the `vpc/` state segment is
> contract-locked even though the code moved under `network/`.

### Proposed module shape

A **create-or-adopt** module (Finding 7): the same resource config serves
greenfield create and brownfield import; import is the primary path.

#### Inputs

| Input | Type | Default | Notes |
|-------|------|---------|-------|
| `name` | `string` | — | Maps to consumers' `vpc_name`; identifier segment of the state key. Validate `^[a-z][a-z0-9-]{0,62}[a-z0-9]$`. |
| `region` | `string` | — | AWS region; also the leading state-key segment. |
| `cidr_block` | `string` | — | VPC CIDR. Must match the existing VPC when adopting. Validate it parses as a CIDR. |
| `availability_zones` | `list(string)` | — | Explicit AZ list (drives `for_each` keys). Length **≥ 2** (Finding 4). Explicit > `az_count` for import-stability. |
| `private_subnets` | `map(string)` | — | AZ → CIDR map for private subnets. **Explicit CIDRs** so an existing VPC imports zero-diff (Finding 7); `cidrsubnet()` only as a greenfield default generator. |
| `public_subnets` | `map(string)` | `{}` | AZ → CIDR map for public subnets. |
| `enable_nat_gateway` | `bool` | `true` | Private-subnet egress. |
| `single_nat_gateway` | `bool` | `true` | One shared NAT (cost) vs one-per-AZ (HA). |
| `enable_dns_hostnames` / `enable_dns_support` | `bool` | `true` | Required for EKS + private DNS. |
| `map_public_ip_on_launch` | `bool` | `false` | Public-subnet auto-assign. |
| `tags` | `map(string)` | `{}` | `merge(var.tags, { Name = … })` per resource. Must match existing tags when adopting. |

#### Resources

`aws_vpc`, `aws_subnet` (public + private, **`for_each` keyed by AZ** for stable
import addresses — never `count`), `aws_internet_gateway`, `aws_eip` +
`aws_nat_gateway`, `aws_route_table` (public + private) +
`aws_route_table_association`, `data.aws_availability_zones` (validation only).
Ship an **import runbook** in `USAGE.md` mapping each resource address to the
`terraform import` command / `import {}` block operators drop into their live
layer.

#### Outputs

- **Contract (stable — never rename):** `vpc_id`, `private_subnet_ids`.
- **Additive (recommended):** `public_subnet_ids`, `vpc_cidr_block`,
  `availability_zones`, `nat_gateway_ids`, `private_route_table_ids`, `igw_id`.

### Proposed test surface

- **`tests/`** (plan-only gate, the primary CI gate): `cidr_block` validation
  negatives, `length(availability_zones) >= 2` negative, private-subnet count ==
  AZ count, contract-output presence.
- **`tests-localstack/`** (Community apply): real VPC/subnets/NAT; assert
  `private_subnet_ids` spans **≥ 2 distinct AZs**; assert contract outputs
  non-empty. A second **adopt smoke** — create a VPC in a `fixtures/` setup, then
  `import {}` it into the module and assert a zero-diff plan (LocalStack supports
  VPC/subnet import).
- **No `tests-localstack-pro/`** (Finding 5).

### Resolved (owner input, 2026-07-14)

- **Component name → `modules/network/vpc/`** (was `modules/vpc/network`).
- **Import mode → create-or-adopt** (resource-managed, import-primary) — *not*
  the read-only data-source adapter. *Marked proposed pending confirmation of the
  import specifics below.*

### Open questions for the DESIGN doc

1. **CIDR strategy:** explicit per-AZ subnet CIDR maps (recommended — import-safe,
   Finding 7) vs computed `cidrsubnet()` (greenfield-only convenience).
2. **Where do `import {}` blocks live:** operator's live/Terragrunt layer
   (recommended — keeps the reusable module `>= 1.1`) vs the module ships
   var-gated import blocks (forces `>= 1.5`).
3. **NAT default:** single shared NAT (recommended — cost) vs one-per-AZ (HA).
4. **Publish `public_subnet_ids` now?** No consumer reads it yet; recommend
   emitting anyway (additive — future ALB/ingress modules will want it).
5. **Dogfood:** should this module *replace* the throwaway networking duplicated
   across the ~6 `tests-localstack/fixtures/setup/` dirs (dedup + real coverage)?
6. **Read-only adapter as a sibling?** If some environments must *never* let TF
   own the network, a thin `data`-source-only variant could ship later — deferred
   unless requested.

### Next steps

1. `docz create design "VPC network module"` — finalize the open questions above.
2. `docz create impl "VPC network module"` — phased build (versions/vars →
   VPC+subnets → IGW/NAT/routes → outputs → import runbook → tests/ →
   tests-localstack/ incl. adopt smoke).
3. Copy `modules/efs/filesystem/` scaffolding as the starting template.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state` (state-key
  convention, producer/consumer wiring).
- DESIGN-0002 (EKS cluster), DESIGN-0007 (RDS family), DESIGN-0008 (EFS) —
  consumers that assume this VPC producer.
- INV-0001 — Module scaffolding, distribution, and presence-check CI.
- RFC-0001 / ADR-0013 / ADR-0014 — module testing strategy (tier split).
- `modules/efs/filesystem/` — cleanest simple-module template.
