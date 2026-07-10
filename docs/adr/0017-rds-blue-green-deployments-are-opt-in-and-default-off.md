---
id: ADR-0017
title: "RDS Blue Green deployments are opt-in and default off"
status: Accepted
author: Donald Gifford
created: 2026-07-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0017. RDS Blue/Green deployments are opt-in and default off

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

AWS RDS and Aurora support **Blue/Green Deployments** — a managed way to make
high-risk changes (major-version upgrades, parameter-group changes, some
storage changes) by standing up a synchronized *green* copy of the database,
letting it catch up via replication, and then cutting over with minimal
downtime. In Terraform this surfaces as the `blue_green_update { enabled =
true }` block on `aws_db_instance` (and, more recently, on Aurora clusters).

The RDS module family (DESIGN-0007: `instance`, `cluster`, `read-replica`,
`serverless`) needs a consistent, fleet-wide answer to *whether and how* the
modules expose Blue/Green, rather than each module re-deciding it. The
question first surfaced in [DESIGN-0012](../design/0012-rds-instance-module-single-awsdbinstance.md)
Q7 (the single-instance module), but the answer should apply to every RDS
module that could offer it.

Blue/Green is powerful but not free: enabling it provisions a **shadow
environment** (double the instances for the duration), changes apply/cutover
semantics, and only pays off for specific, deliberate upgrade events. It is
the wrong thing to have on by default for the common create/steady-state
path the modules optimize for.

This decision follows the fleet's established posture of **safe, cheap
defaults with explicit opt-in for advanced/cost-bearing features** — the same
posture as module-managed-vs-BYO KMS, IAM database authentication
(default off), Multi-AZ (default off, DESIGN-0012 Q4), and storage
autoscaling (default off, DESIGN-0012 Q3).

## Decision

**When an RDS module adds Blue/Green deployment support, it is exposed as an
opt-in toggle that defaults to off.** Concretely:

- The capability is gated behind a boolean input (e.g.
  `var.blue_green_update_enabled`) whose default is `false`. Blue/Green is
  never enabled implicitly.
- The module never *requires* Blue/Green; the create and steady-state paths
  are unchanged when the toggle is off (no shadow environment, no cutover
  semantics).
- The actual cutover is an **operator workflow** (a deliberate,
  reviewed apply for a specific upgrade), documented in the module's
  `README.md` / `USAGE.md` — not a CI or default-plan behaviour.
- This ADR governs the *posture*; it does **not** mandate that any specific
  module implement Blue/Green now. DESIGN-0012 Q7 defers implementation from
  the `instance` module's v1. This ADR is the standing contract for if/when
  it lands, in any RDS module.

## Consequences

### Positive

- **Consistent contract** across the RDS family — every module that offers
  Blue/Green offers it the same way (default-off boolean), so consumers learn
  it once.
- **Cheap, simple default path** — the common case pays no cost or complexity
  for a feature it doesn't use.
- **Deliberate upgrades** — enabling Blue/Green is a visible, reviewed change
  (a non-default toggle flip), which is exactly the risk posture a
  major-version upgrade warrants.
- Matches the fleet's existing opt-in-for-advanced-features convention, so it
  needs no special explanation.

### Negative

- Consumers who want low-downtime upgrades must know to flip the toggle; it is
  not discoverable from defaults alone (mitigated by module docs).
- A future module that implements Blue/Green carries extra input + test
  surface (a default-off toggle and its plan-time coverage) even before any
  consumer uses it.

### Neutral

- The toggle's presence says nothing about *when* Blue/Green is implemented —
  that remains a per-module scoping decision (e.g. DESIGN-0012 Q7 defers it).
- The cutover mechanics (green-environment lifecycle, switchover) stay an
  operator concern, consistent with the fleet's "Terraform manages the AWS
  API surface; runbook actions are out-of-band" posture.

## Alternatives Considered

- **Default Blue/Green on** — rejected. It would provision a shadow
  environment and change apply semantics for every consumer, imposing cost and
  complexity on the overwhelmingly common path that never does a low-downtime
  major upgrade.
- **Per-module ad-hoc decisions** — rejected. Letting each RDS module decide
  independently invites an inconsistent surface (some default-on, some
  default-off, some absent) and re-litigates the same trade-off repeatedly.
- **Never support Blue/Green** — rejected as too absolute. Low-downtime major
  upgrades are a real operator need; the module family should be *able* to
  offer it, just not by default.

## References

- [DESIGN-0012](../design/0012-rds-instance-module-single-awsdbinstance.md) — RDS instance module (Q7 defers Blue/Green from v1; this ADR records the fleet posture it points to).
- [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module family layout.
- [ADR-0001](0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition (fleet-wide conventions this decision is consistent with).
- [`aws_db_instance` `blue_green_update`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance#blue_green_update) — provider reference.
- [Amazon RDS Blue/Green Deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html) — AWS documentation.
