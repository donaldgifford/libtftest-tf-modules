<!-- markdownlint-disable-file MD025 MD041 -->
# Security Group (generic ingress allowlist)

A standalone **ingress-allowlist** security group with standard outputs
([DESIGN-0026](../../../docs/design/0026-generic-security-group-module.md)).
Typed granular rules keyed by logical name, **live** prefix-list
references, and a fail-closed world-open guard. The rule content *is*
the product: webhook source lists, corp ranges and partner CIDRs churn,
and this module's value is reviewed, plan-diffed allowlist changes with
per-rule lifecycle.

## Scope: what this module is not for

**Frontend-style standalone security groups only.** This module must
never become the fleet's SG-of-everything.

- **SGs belonging to a resource-owning module** — the EKS cluster and
  node SGs, the RDS SGs, the EFS mount-target SGs. Those stay in
  `eks/cluster`, `rds/*` and `efs/filesystem`, where they live beside
  the resource whose lifecycle they share.
- **Backend rules** — the AWS Load Balancer Controller owns backend and
  node-SG rules. It is closest to the source that defines them. Give it
  a frontend SG and it manages the backend rules referencing that SG.
- **Prefix-list management** — this module consumes prefix-list *ids*.
  Creating and maintaining `aws_ec2_managed_prefix_list` entries would
  be a future `network/prefix-list` sibling.
- **Kubernetes objects** — the Gateway/Ingress annotation carrying the
  SG id is chart-side, through live-repo values.

## Rules are granular and keyed by logical name

Every rule is its own `aws_vpc_security_group_ingress_rule` /
`_egress_rule`, `for_each`'d by the map key — the `eks/cluster` idiom
productized. Never inline `ingress {}` / `egress {}` blocks: mixing
inline and granular rules is the known drift pathology, and an inline
block churns the whole SG on a single-rule edit.

Because the logical name **is** the address, removing one allowlist
entry plans as exactly one destroy and never churns a sibling. That is
what makes a 30-entry allowlist reviewable.

Each rule names **exactly one** source, rejected at plan otherwise:

| Field | Use for |
|---|---|
| `cidr_ipv4` | An IPv4 range |
| `cidr_ipv6` | An IPv6 range |
| `prefix_list_id` | A managed prefix list — **live**, see below |
| `referenced_security_group_id` | Another security group's members |

`description` is required on every rule: the allowlist is an audit
surface, and a rule nobody can explain is a rule nobody can safely
remove. `to_port` defaults to `from_port` (the single-port case).

### Ports depend on the protocol, and the module enforces which

| `ip_protocol` | `from_port` | `to_port` |
|---|---|---|
| `tcp`, `udp` | required | optional, collapses to `from_port` |
| `icmp`, `icmpv6` | required — the ICMP **type** | required — the ICMP **code** (`-1` for any) |
| `-1`, a number `0`-`255` | must be absent | must be absent |

ICMP is the trap: `from_port` is the type and `to_port` is the *code*,
not a range. Left to collapse, `{ from_port = 8, ip_protocol = "icmp" }`
reads as "allow ping" and resolves to type 8 / code 8, which matches
nothing — echo requests carry code 0. Both are therefore required on an
ICMP rule. For all-protocols and numeric protocols, AWS **ignores**
ports, so accepting them would let a rule read as port-scoped when it is
not; they are rejected instead.

### Descriptions are charset-constrained by AWS, not by us

EC2 accepts only `a-z A-Z 0-9`, spaces, and `._-:/()#,@[]+=;{}!$*` in a
rule description (the security group's own description also allows `&`).
This is enforced **server-side only** — the provider does not check it,
and **LocalStack does not enforce it either**, so an apply suite is not
a gate for this. The module validates both at plan.

The reason this is a validation and not a note: the module's own default
`description` once carried a U+2014 em dash, so every invocation that
did not override it would have failed at apply against real AWS, after
the create call, on a string nobody would think to look at.

## Worked example — `gateway-frontend-public`

```hcl
module "gateway_frontend_public" {
  source = "../../modules/network/security-group"

  name        = "gateway-frontend-public"
  description = "Public Gateway frontend - webhooks and corp hairpin"
  vpc_name    = "libtftest-vpc"

  ingress_rules = {
    # LIVE reference — see the callout below.
    github-webhooks = {
      description    = "GitHub webhook delivery to the public Gateway"
      from_port      = 443
      prefix_list_id = "pl-0123456789abcdef0"
    }

    # The hairpin posture — see the callout below.
    corp-egress = {
      description = "Corp public egress IPs (hairpin)"
      from_port   = 443
      cidr_ipv4   = "203.0.113.0/24"
    }
  }

  tags = { ManagedBy = "terraform", Component = "gateway" }
}
```

> **Prefix-list rules are LIVE.** A rule referencing `prefix_list_id`
> tracks the list: adding a CIDR to the list takes effect **without a
> Terraform apply**, and the plan for this stack will not change.
>
> This is the deliberate counterpart to the EKS public-endpoint fence,
> which expands prefix lists at **plan** time because the EKS API takes
> literal CIDRs — see
> [`eks/cluster`'s fence callout](../../eks/cluster/README.md), which
> points here for exactly this reason. If you need live tracking, it is
> a security-group rule's job. If you need a reviewable snapshot, it is
> the fence's.

### The guard cannot see inside a prefix list

> **The world-open guard cannot see inside a prefix list.** The guard
> below inspects the literal `cidr_ipv4` / `cidr_ipv6` fields only. A
> prefix list containing `0.0.0.0/0` admits the world and this module
> will not stop it, **by design**: the reference is live, so expanding
> the list at plan time would be false assurance — the list can be
> edited world-open a minute after the apply, which is what "live"
> means.
>
> **Prefix-list contents are the list owner's audit surface**, not this
> module's. A `referenced_security_group_id` source has no equivalent
> hole: an SG reference admits that SG's members, never the world.

### The hairpin posture

> **The hairpin posture.** Corp traffic egresses the corp network and
> re-enters through the public ALB's ingress rule, so what belongs in
> the allowlist is the corp **public egress** ranges, not the internal
> ones. This is an accepted cost, not an oversight — the alternative is
> a private path this Gateway class does not have.

**Consuming the id.** `security_group_id` flows to the Load Balancer
Controller's frontend-SG annotation through live-repo chart values. With
a caller-provided frontend SG, the controller manages the backend rules
referencing it — backend stays the controller's.

## World-open ingress is fail-closed

Any **ingress** rule whose literal CIDR is a `/0` fails at plan unless
you set `allow_world_open_ingress = true`. A deliberately public
frontend is one explicit, reviewable line; the guard exists for the
pasted-wide-open accident. The error names the offending rule keys.

The test is `endswith(cidr, "/0")`, not a comparison against the strings
`0.0.0.0/0` and `::/0`. That distinction is the whole guard: **IPv6 has
many legal spellings of `::/0`** — `0::/0` and the fully expanded
`0000:0000:...:0000/0` among them — and the provider's CIDR validator
accepts all of them. A string compare caught one spelling and let the
rest through (the bug this module shipped with in review; it is also
upstream provider issue #15982). `/0` is the only prefix length whose
literal text ends in `/0`, so the suffix test is exact.

### What the guard does not catch

It is a **guard against the accident, not a proof of non-exposure.**
Three known ways to admit the world without tripping it, all deliberate:

- **A `/1` split.** `0.0.0.0/1` plus `128.0.0.0/1` in two rules covers
  the entire IPv4 space and neither is a `/0`. Catching this means
  unioning CIDR arithmetic across the whole map — and any threshold
  chosen there (`/1`? `/4`?) rejects legitimate large allowlists. A
  caller who writes two half-internet rules has not slipped.
- **A prefix list containing `0.0.0.0/0`** — see the callout above. The
  reference is live, so expanding it at plan time would be false
  assurance.
- **Egress.** World egress *is* this module's default posture
  (`allow_all_egress = true` emits exactly that rule), so rejecting
  `0.0.0.0/0` in the typed `egress_rules` map would reject a shape the
  default already grants.

## Egress: the default is explicit, not implied

`allow_all_egress = true` (the default) emits one granular
all-protocols rule to `0.0.0.0/0`.

This is **not** redundant with AWS's own default. The provider
**revokes** the default allow-all egress when it creates a security
group, so a module with no egress surface would ship SGs that silently
fail ALB health checks and target traffic — discovered live, not at
plan. Emitting it as a real resource keeps the posture visible in every
plan rather than implied by its absence.

For a restricted posture, set `allow_all_egress = false` **and** declare
`egress_rules`. Doing one without the other is rejected at plan:
`allow_all_egress = true` alongside a non-empty `egress_rules` used to
be additive, which is a silent widening. A caller writing egress rules
is trying to restrict egress, and the all-egress rule is wider than
anything they can write — yet in the plan it shows up only as an
**unchanged** resource, which is exactly what reviewers skim past.

The logical key `all-egress` is **reserved** in `egress_rules`: the
module's own default rule already tags itself
`Name = "<name>-all-egress"`, and a caller rule by that key would
produce two rules disputing one Name tag.

## Replacement: `name_prefix`, not a fixed name

SG `name` and `description` are **create-time** on AWS — editing either
replaces the security group. The module therefore uses
`name_prefix = "<name>-"` with `create_before_destroy`:

- A fixed name would make a destroy-first replacement of an
  ALB-attached SG deadlock on `DependencyViolation`.
- It would also make create-before-destroy impossible, because the
  successor collides on the name.

**What this does not fix:** a replacement still mints a **new security
group id**. Any chart-side annotation or cross-stack consumer holding
the old id needs updating in the same change. CBD removes the deadlock
and the collision, not the id change.

`security_group_name` outputs the **physical** suffixed name (what the
console shows); the friendly `var.name` rides the `Name` tag.

## Adopting an existing security group

The hub's frontend SGs are built manually today and adopted later
(INV-0011's sequencing tier). Import blocks live in the **live repo**,
targeting this module's addresses, piecewise:

```hcl
# 1. the security group — by sg-... id
import {
  to = module.gateway_frontend_public.aws_security_group.this
  id = "sg-0123456789abcdef0"
}

# 2. each rule — by sgr-... id, into its LOGICAL key
import {
  to = module.gateway_frontend_public.aws_vpc_security_group_ingress_rule.this["github-webhooks"]
  id = "sgr-0123456789abcdef0"
}
```

**Match reality first, converge second.** Write the rule map to mirror
the live SG verbatim, import, verify the plan is zero-diff, and only
then converge conventions (descriptions, tags) in later reviewed plans.
Converging in the same change as the import turns a provably-empty plan
into one nobody can read.

**When tightening a live allowlist, sequence adds before removes.** A
rule's description updates in place, but a **source or port change
replaces that rule** — a brief window with the rule absent on an SG
serving live traffic.

`ingress_rule_ids` / `egress_rule_ids` map each logical name to its
`sgr-...` id, which is how you find the ids to import and how an
operator chasing a console rule gets back to the name the plan speaks
in.

## Remote-state key contract

Published at the ADR-0020 **`sg`** shape:

```text
<account_name>/<region>/sg/<name>/terraform.tfstate
```

`<name>` is the standard triple coupling — SG name == live-repo folder
== future consumer input. No Terraform consumer is wired yet; the row
reserves the shape the way `iam` and `secrets` were reserved ahead of
theirs, because the alternative is a producer publishing into an
undocumented shape rather than publishing nothing. Foreseeable first
consumers: a sibling SG stack taking this one as
`referenced_security_group_id`, or an `eks/cluster` additional-SG input.

This module is also the **seventh consumer** of the `vpc` shape, reading
`vpc_id` from `<account_name>/<region>/vpc/<vpc_name>/terraform.tfstate`.

## Tests

| Suite | Tier | What it proves |
|-------|------|----------------|
| `tests/` | plan (the gate), 33 runs | All four source types in one plan with each asserting its own field is set and the other three null; stable addresses by logical key; the `to_port` collapse, the ICMP type/code pair and the all-protocols shape; a bare call pinning every default; both egress postures; the ADR-0020 key and the `assume_role` arn; 22 rejections, each verified **by isolated message probe** to fire the rule it names |
| `tests-localstack/` | Community apply | The SG and all rule types round-trip against a real (emulated) EC2 API — see `FINDINGS.md` |

Full variable/output reference: [USAGE.md](USAGE.md).
