---
id: INV-0008
title: "RDS managed master secret rotation schedule and manage-false guardrails"
status: In Progress
author: Donald Gifford
created: 2026-07-29
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0008: RDS managed master secret rotation schedule and manage-false guardrails

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-07-29

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [F1 — `manage_master_user_password = false` is a migration escape hatch, not a BYO-password mode](#f1--manage_master_user_password--false-is-a-migration-escape-hatch-not-a-byo-password-mode)
  - [F2 — The proxy already fails closed on the no-auth-path combination](#f2--the-proxy-already-fails-closed-on-the-no-auth-path-combination)
  - [F3 — Rotation is a client-caching problem the fleet already absorbs](#f3--rotation-is-a-client-caching-problem-the-fleet-already-absorbs)
  - [F4 — The managed secret's rotation schedule is adjustable, but not disableable](#f4--the-managed-secrets-rotation-schedule-is-adjustable-but-not-disableable)
  - [F5 — Terraform-managing the schedule needs a probe (pending)](#f5--terraform-managing-the-schedule-needs-a-probe-pending)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Open Questions](#open-questions)
  - [1. What variable surface controls the rotation schedule?](#1-what-variable-surface-controls-the-rotation-schedule)
  - [2. What shape does the `manage = false` guardrail take?](#2-what-shape-does-the-manage--false-guardrail-take)
  - [3. Which modules take the change?](#3-which-modules-take-the-change)
- [References](#references)
<!--toc:end-->

## Question

Two related questions about the AWS-managed master user secret across the RDS
fleet (`rds/instance`, `rds/serverless`, `rds/cluster`):

1. Can the managed secret's auto-rotation cadence be slowed from AWS's 7-day
   default to a fleet default of **90 days**, managed by Terraform inside the
   module — and does that mechanism (`aws_secretsmanager_secret_rotation`
   adopting an RDS-managed secret) actually work?
2. Should the `manage_master_user_password = false` escape hatch be guarded by
   a plan-time validation, given the module offers no password input and the
   proxy composition loses its authentication path when the managed secret is
   absent?

## Hypothesis

1. Yes — Secrets Manager supports editing the rotation schedule of an
   RDS-managed master secret (`RotateSecret` with a `ScheduleExpression`, no
   Lambda), and the AWS provider's `aws_secretsmanager_secret_rotation`
   resource supports managed-rotation secrets (no `rotation_lambda_arn`), so
   the module can own a `rate(90 days)` schedule declaratively. Needs a probe
   (F5) because adopting an AWS-created secret from a module that did not
   create it has ordering/adoption semantics worth verifying.
2. Yes — `manage = false` currently produces either an apply-time API failure
   (fresh create: no `MasterUserPassword` is ever sent) or a proxy with no
   auth path; both are discoverable earlier and more clearly at plan time.

## Context

**Triggered by:** an operator-experience question in the IMPL-0011 line —
"if we set `manage_master_user_password = false` for `rds/instance`, how do I
set the password?" — which unwound into the rotation-annoyance discussion:
the 7-day default rotation of the managed master secret is operationally
noisy for humans and any client that caches credentials.

The fleet's credential design (DESIGN-0010 / RFC-0002): the DB-owning modules
default `manage_master_user_password = true`; the AWS-managed Secrets Manager
secret is the single credential source; `rds/proxy` composes against it via
remote state (`master_user_secret_arn` + least-privilege `GetSecretValue` /
`kms:Decrypt`).

## Approach

1. Read the actual module surfaces: password-related variables and
   `aws_db_instance` arguments in `rds/instance`; the proxy's
   `master_user_secret_arn` consumption and preconditions. *(Done — F1, F2.)*
2. Establish rotation-impact semantics (do existing connections survive a
   rotation; who needs the new value when). *(Done — F3.)*
3. Establish what AWS allows for the managed secret's schedule. *(Done — F4.)*
4. **Probe (pending):** on LocalStack Pro (Secrets Manager + RDS are
   Pro-covered), apply an `rds/instance` with the managed secret plus an
   `aws_secretsmanager_secret_rotation` adopting `master_user_secret_arn` with
   `rotation_rules { schedule_expression = "rate(90 days)" }` — verify
   create/adopt, plan stability (no perpetual diff), and destroy ordering.
   Fall back to a real-AWS spot check if LocalStack's parity is incomplete.
5. Write the validation shape for `manage = false` (OQ 2) and confirm it
   fails the intended combinations in plan tests.

## Environment

| Component | Version / Value |
|-----------|----------------|
| AWS provider | `~> 6.2` (resolving 6.5x) |
| LocalStack Pro | `2026.7.0` (named volume, per `rds/*` FINDINGS) |
| Modules in scope | `rds/instance`, `rds/serverless`, `rds/cluster` (secret owners); `rds/proxy` (consumer, no change) |

## Findings

### F1 — `manage_master_user_password = false` is a migration escape hatch, not a BYO-password mode

`rds/instance` exposes the toggle but **no password variable**, and
`aws_db_instance.this` sets no `password`/`password_wo` argument. On a fresh
create with `manage = false`, the RDS API rejects the call (no
`MasterUserPassword` is ever sent). The variable's own description scopes the
opt-out to "operators migrating from a pre-existing secret" — i.e., flipping
an **existing** instance to `false` deletes the managed secret while the
current password keeps working, with rotation becoming the operator's
problem. The same shape holds for `serverless` and `cluster`.

### F2 — The proxy already fails closed on the no-auth-path combination

`rds/proxy` precondition (`proxy.tf:47-48`):

```hcl
condition     = local.master_user_secret_arn != null || var.require_iam_auth
error_message = "The proxy has no authentication path: the target's master_user_secret_arn is null (manage_master_user_password = false) and require_iam_auth = false. …"
```

So the *consumer* side already guards this — but only when a proxy is
composed, and only at proxy-plan time. The DB module itself lets the broken
configuration (fresh create, `manage = false`) through to an apply-time API
error. A plan-time guard belongs on the DB modules (OQ 2).

### F3 — Rotation is a client-caching problem the fleet already absorbs

RDS does not drop existing connections on rotation; only **new** connections
need the current value. The designed absorbers, both already shipped:
`rds/proxy` fetches the secret at connection time (rotation invisible to
every client behind it), and IAM database auth removes the password entirely
(`require_iam_auth`). Direct-connecting apps use fetch-at-connect /
Secrets Manager caching clients; humans use a fetch-then-connect wrapper.
The remaining annoyance is purely the 7-day cadence — addressed by F4.

### F4 — The managed secret's rotation schedule is adjustable, but not disableable

The 7-day default is only the initial schedule. Secrets Manager accepts a
schedule edit on the RDS-managed secret:

```sh
aws secretsmanager rotate-secret --secret-id <master_user_secret_arn> \
  --rotation-rules 'ScheduleExpression=rate(90 days)'
```

Rotation cannot be disabled while `manage_master_user_password = true`; the
only rotation-off path is `manage = false`, which per F1/F2 is the wrong
trade (never-rotated master credential + proxy auth-path loss).

### F5 — Terraform-managing the schedule needs a probe (pending)

The declarative shape is `aws_secretsmanager_secret_rotation` with
`secret_id = master_user_secret_arn` and `rotation_rules { schedule_expression
= "rate(90 days)" }` and **no** `rotation_lambda_arn` (managed rotation). To
verify before implementation (Approach step 4): provider support for adopting
a secret the module didn't create, plan stability after adoption, LocalStack
Pro parity for `RotateSecret` on managed secrets, and destroy behavior (the
rotation resource must not attempt to remove managed rotation in a way the
API rejects). Outcome lands here as F5-resolved.

## Conclusion

**Answer:** Pending F5. Directionally: **yes** — slow the fleet default to
90 days inside the modules, and **yes** — guard `manage = false` at plan
time. `manage = false` remains an escape hatch (existing-instance
migrations), never a password-management mode: the module will continue to
ship no password input; operators who need an explicit credential read the
managed secret or use IAM auth.

## Recommendation

1. **90-day rotation default, module-owned** (pending F5): each secret-owning
   module (`instance`, `serverless`, `cluster`) gains an
   `aws_secretsmanager_secret_rotation` adopting its managed master secret
   with a `rate(90 days)` default schedule, surfaced per OQ 1. No change to
   `proxy` (consumer) or `read-replica` (no secret).
2. **Plan-time guardrail on `manage = false`** per OQ 2: the broken
   fresh-create combination fails at plan with an actionable message instead
   of at the RDS API.
3. Implementation follows as a small IMPL (or single PR) after the OQs are
   answered and F5 is probed; plan tests cover the new validation and the
   rotation resource's presence/absence per configuration.

## Open Questions

### 1. What variable surface controls the rotation schedule?

- **a. (Recommended)** `master_secret_rotation_days` (`number`, default
  `90`, `null` = leave AWS's default schedule untouched / emit no rotation
  resource). Days-based `automatically_after_days` maps 1:1 to the intent,
  validates trivially (1–1000), and avoids operators hand-writing
  `rate(...)`/`cron(...)` strings.
- b. `master_secret_rotation_schedule` (`string`, default `"rate(90 days)"`,
  `null` = no rotation resource) — full `ScheduleExpression` flexibility
  (cron windows, business-hours rotation) at the cost of a free-text surface
  and validation complexity.
- c. Hardcode `rate(90 days)` with no variable — smallest surface, but bakes
  a policy number into three modules and forces a module release to change
  cadence.
- Other: (your call)

### 2. What shape does the `manage = false` guardrail take?

- **a. (Recommended)** Plan-time precondition on the DB resource:
  `manage_master_user_password || var.iam_database_authentication_enabled`,
  with an error message spelling out the two valid paths (keep the managed
  secret, or IAM auth) and the migration escape-hatch caveat. Mirrors the
  proxy's existing fail-closed precondition (F2) at the source, and keeps
  the migration path available (an imported instance sets IAM auth or keeps
  its password out-of-band — the precondition documents that reality).
- b. Remove the variable entirely (always-managed). Cleanest security
  posture, but kills the documented migration escape hatch and is a breaking
  change across three modules.
- c. Acknowledgment variable (`allow_unmanaged_master_password = true`
  required alongside `manage = false`) — makes the foot-gun explicit without
  constraining it, but adds a surface whose only job is friction.
- Other: (your call)

### 3. Which modules take the change?

- **a. (Recommended)** All three secret-owning modules (`rds/instance`,
  `rds/serverless`, `rds/cluster`) take both the rotation default and the
  guardrail in one PR — the credential surface is identical across them, and
  a split fleet (one module rotating quarterly, two weekly) is the kind of
  drift the fleet-consistency docs exist to prevent.
- b. `rds/instance` first (the module that triggered the question), siblings
  as follow-ups — smaller PR, but leaves the fleet split in the interim.
- Other: (your call)

## References

- DESIGN-0010 / RFC-0002 — proxy composition against the managed master
  secret (`master_user_secret_arn`, least-privilege secret access)
- DESIGN-0012 / IMPL-0011 — `rds/instance` (the credential surface under
  discussion; `variables.tf` `manage_master_user_password` description)
- `modules/rds/proxy/proxy.tf:47-48` — the existing no-auth-path
  precondition (F2)
- AWS docs — *Managing master user passwords with Secrets Manager* (managed
  rotation; schedule modification via `RotateSecret`)
- AWS provider — `aws_secretsmanager_secret_rotation` (managed-rotation
  support, no `rotation_lambda_arn`)
