---
id: ADR-0001
title: "Cross-module composition via terraform_remote_state"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0001. Cross-module composition via terraform_remote_state

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
- [Consequences](#consequences)
  - [Positive](#positive)
  - [Negative](#negative)
  - [Neutral](#neutral)
- [Alternatives Considered](#alternatives-considered)
- [References](#references)
<!--toc:end-->

## Status

Accepted

## Context

The four EKS modules in this repo (cluster, managed-node-group, addons,
pod-identity-access) need to share data: the node group needs the cluster's
endpoint and CA, the addons module needs the cluster name and version, the
pod-identity-access module needs the cluster name plus any pre-created
controller role ARNs. There are two common ways to wire that:

1. **Direct module composition** — a wrapper `main.tf` that calls each
   module and pipes `module.cluster.outputs.cluster_endpoint` into
   `module.node_group.cluster_endpoint`.
2. **Remote state lookup** — each module is its own Terragrunt stack with
   its own state file, and downstream modules read upstream outputs via
   `data.terraform_remote_state`.

The repo's parent organization runs the **Gruntwork "live repo" model**
(infrastructure-modules + infrastructure-live, generated and scaffolded
with Gruntwork Boilerplate). In that model each environment / region /
cluster is a Terragrunt stack with its own state file, and the contract
between stacks is exactly the set of outputs each one publishes. The
existing EKS module fleet already wires consumers via
`data.terraform_remote_state` against an S3 backend. The intent of *this*
repo is to ship modules that drop straight into that topology with no
re-plumbing.

The state file is the **last-known-good record** of what was actually
provisioned. Pointing downstream consumers at it (via remote state
references) means pointing at ground truth. If state has drifted from
reality, that drift is the bug to fix — at the source, by reconciling
state — not something to paper over by introducing a separate parallel
contract surface between stacks.

## Decision

Every module in this repo consumes other modules' outputs **only** through
`data.terraform_remote_state` against an S3 backend, never through direct
module composition. The remote-state key convention is:

```hcl
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region = var.region
  }
}
```

Every consumer module therefore takes `remote_state_bucket`, `region`, and
`cluster_name` as inputs and reads everything else from remote state. The
cluster module (DESIGN-0002) is the source-of-truth state file; its outputs
are a stable contract — renaming or removing one is a breaking change to
every downstream module.

**Reference remote-state outputs at the use site, not via locals.** Avoid
adding `locals { cluster_endpoint = data.terraform_remote_state.eks.outputs.cluster_endpoint }`
just to rename or alias a remote-state output. Use
`data.terraform_remote_state.eks.outputs.cluster_endpoint` directly where
it's consumed. Locals are reserved for cases that do meaningful
computation — combining multiple sources, applying conditionals, or
deriving a value (e.g., `ami_type = local.is_arm64 ? "..." : "..."`).

The deeper reason: we aim for modules to behave as closely to **pure
functions** as Terraform allows — same inputs (variables + remote state
outputs) produce the same plan. Aliasing locals introduce hidden state
between input and use site, which is non-deterministic in the sense that
a reader has to chase the chain to know what's really being passed.
Reading remote state at the use site keeps the data flow obvious and the
module behavior reproducible.

For the same reason, **prefer remote-state reads over live AWS data
sources** wherever the resource is owned by another module in this fleet.
A `data.terraform_remote_state.vpc.outputs.private_subnet_ids` read returns
the subnet IDs as they were *last applied* — a fixed snapshot. A
`data.aws_subnets` filter, by contrast, returns whatever AWS reports at
plan time, which may have drifted from the VPC stack's state. The
remote-state read buffers downstream consumers from cascading drift in
upstream resources; live data sources propagate it.

**Identity-class data sources are the carve-out.**
`data.aws_caller_identity.current` is allowed. The account ID it returns
is identity, not resource state — it does not drift, the call is free,
and hoisting it as `var.account_id` would only add variable plumbing
without any determinism gain (Boilerplate would resolve it via the same
`sts:GetCallerIdentity` API anyway). Same logic would apply to
`data.aws_partition` if needed. The carve-out is narrow: anything that
represents a *resource* (VPC, subnet, KMS key, IAM role, etc.) must come
from remote state or an input variable, not from a live AWS API filter.

**Hoist derivation up to Boilerplate-generated Terragrunt, not into
module-local computation.** When a value can be derived from a smaller
input (architecture → AMI type, account alias → tags, region → log group
prefix), do that derivation in the live repo's Terragrunt config, which
Gruntwork Boilerplate scaffolds. The module receives a fully-formed input
object (e.g., `var.architecture = { name, ami_type, gvisor_arch, k8s_arch,
default_instance_types }` or `var.tags = { Account, ClusterName, ... }`)
and references it at the use site. This:

- Keeps the derivation table visible to operators reviewing the live
  repo's Terragrunt files, where they can sanity-check it.
- Lets the module stay a thin shell around resources (closer to a pure
  function of inputs → plan).
- Avoids tying the module to AWS-API reads (`data.aws_iam_account_alias`,
  `data.aws_region`, `data.aws_caller_identity`) that exist solely to
  feed an internal `local.X` aggregation.

The only locals that survive in this model are ones that combine multiple
inputs in a way that genuinely belongs to the module's resource topology
(e.g., a count gate, a conditional `coalesce` over inputs that can't be
collapsed up the stack). If a local *only* renames or re-shapes inputs,
hoist it to Terragrunt instead.

## Consequences

### Positive

- Drops into the existing EKS module-set fleet topology without re-plumbing.
- Each module is its own Terragrunt stack, applied independently. Smaller
  blast radius per apply.
- Cluster module's output set becomes an explicit contract — easier to
  reason about than ad-hoc module-input wiring.
- Eliminates monolithic root modules that try to provision a whole cluster
  in one apply; supports per-environment hierarchy via Terragrunt.
- Consumers always read the last-known-good state. There is one source of
  truth per resource set, not a derived alias of it.
- Scaffolding via Gruntwork Boilerplate produces consumer stacks that
  consume this contract by default — no per-module wiring code.
- Modules approximate pure functions: a `terraform plan` against the same
  variables + remote-state inputs produces the same plan. Reasoning about
  changes is local to the module under edit.
- Drift in an upstream resource doesn't silently cascade into downstream
  plans — downstream reads a frozen snapshot from the upstream state file,
  not the live resource.
- Derivation tables (architecture → AMI / arch / instance types; account →
  tag set) live in Boilerplate-generated Terragrunt, where operators can
  see them on review, instead of being buried inside module locals.

### Negative

- Output changes are now a breaking change to consumers. Renaming an output
  requires a coordinated migration across every consumer stack.
- libtftest tests must seed a fake cluster state in a test S3 bucket
  (LocalStack-backed) rather than just exercising the module directly.
- Cycle detection across stacks is the operator's responsibility — Terraform
  can't see the implicit dependency graph that spans state files.
- Reading directly at the use site (instead of through locals) makes diffs
  noisier when an output is renamed — the rename has to land everywhere.
  Mitigated by the rarity of output renames and by codebase grep.
- State drift between what's deployed and what the state file says becomes
  load-bearing: a downstream consumer reading from a drifted state file
  will see stale data. The remediation is to fix the drift at the source,
  not to bypass remote state.

### Neutral

- The convention key (`${region}/eks/${cluster_name}/terraform.tfstate`) is
  a contract that lives in the operator's Terragrunt config, not in any
  module's HCL. Code review can't enforce it.

## Alternatives Considered

**Direct module composition.** A single root `main.tf` calling all four
modules and wiring `module.x.outputs` to `module.y.inputs`. Rejected:
incompatible with the existing fleet topology, forces monolithic applies,
and would require re-pluming when adopting these modules in environments
that already use the remote-state pattern.

**Pass-through variables.** Caller stacks read the upstream state and pass
specific outputs as variables into each downstream module. Rejected as
boilerplate — every consumer would reimplement the same
`data.terraform_remote_state` block in its wrapper. Keeping the block
inside the module concentrates the pattern in one place.

**SSM Parameter Store as the contract surface.** Cluster module writes
outputs to SSM Parameters, downstream modules read them. Considered but
rejected for v1: adds an extra resource per output, no Terraform-native
locking semantics, and the existing fleet already standardizes on remote
state.

## References

- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (Cross-module wiring).
- DESIGN-0002 — EKS Cluster Module (Remote-state contract).
- DESIGN-0003 — EKS Addons Module (Cross-module references).
- DESIGN-0004 — EKS Pod Identity Access Module (Cross-module references).
- `terraform_remote_state` data source: <https://developer.hashicorp.com/terraform/language/state/remote-state-data>
- S3 backend: <https://developer.hashicorp.com/terraform/language/backend/s3>
- Gruntwork "live repo" pattern: <https://docs.gruntwork.io/library/usage/repo-organization/>
- Gruntwork Boilerplate: <https://github.com/gruntwork-io/boilerplate>
