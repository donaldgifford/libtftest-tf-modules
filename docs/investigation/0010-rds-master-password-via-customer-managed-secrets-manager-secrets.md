---
id: INV-0010
title: "RDS master password via customer-managed Secrets Manager secrets"
status: Concluded
author: Donald Gifford
created: 2026-08-11
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0010: RDS master password via customer-managed Secrets Manager secrets

**Status:** Concluded
**Author:** Donald Gifford
**Date:** 2026-08-11

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [F1 — Current state: three modes already exist, two of them implicit](#f1--current-state-three-modes-already-exist-two-of-them-implicit)
  - [F2 — The no-password-in-state mechanics exist and are verified in the pinned provider](#f2--the-no-password-in-state-mechanics-exist-and-are-verified-in-the-pinned-provider)
  - [F3 — Probed: what the test tiers can and cannot see](#f3--probed-what-the-test-tiers-can-and-cannot-see)
  - [F4 — Password lifecycle is version-gated, in both directions](#f4--password-lifecycle-is-version-gated-in-both-directions)
  - [F5 — Proxy composition survives untouched if the output contract is reused](#f5--proxy-composition-survives-untouched-if-the-output-contract-is-reused)
  - [F6 — Rotation is the one thing customer-managed secrets lose](#f6--rotation-is-the-one-thing-customer-managed-secrets-lose)
  - [F7 — The producer-module option is orthogonal, not competing](#f7--the-producer-module-option-is-orthogonal-not-competing)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Open Questions](#open-questions)
  - [1. What is the overall architecture?](#1-what-is-the-overall-architecture)
  - [2. What variable surface expresses the mode?](#2-what-variable-surface-expresses-the-mode)
  - [3. How is the password generated in create mode?](#3-how-is-the-password-generated-in-create-mode)
  - [4. What happens to rotation in the customer-managed modes?](#4-what-happens-to-rotation-in-the-customer-managed-modes)
  - [5. How are create-mode secret naming and deletion handled?](#5-how-are-create-mode-secret-naming-and-deletion-handled)
  - [6. How is the required_version floor raise rolled out?](#6-how-is-the-required_version-floor-raise-rolled-out)
- [References](#references)
<!--toc:end-->

## Question

Can the three secret-owning RDS modules (`rds/instance`, `rds/serverless`,
`rds/cluster`) support two new master-password paths — (1) the module
creates a customer-managed Secrets Manager secret holding the password,
and (2) the module sets the DB password from an existing Secrets Manager
secret — **without the password ever landing in Terraform state, plan
output, or code**, and without breaking the `rds/proxy` composition or
the AWS-managed-secret default shipped by INV-0008 / IMPL-0017?

## Hypothesis

Yes, via two Terraform features the fleet has not used yet: **ephemeral
resources** (Terraform ≥ 1.10) for values that exist only in memory
during an operation, and **write-only arguments** (Terraform ≥ 1.11,
`aws_db_instance.password_wo` / `aws_rds_cluster.master_password_wo` /
`aws_secretsmanager_secret_version.secret_string_wo`) for sending those
values to the API without persisting them. The classic
`random_password`-resource pattern is expected to fail requirement (1)
because `random_password` stores its result in state.

## Context

Today the fleet's only supported credential path is the AWS-managed
master secret (`manage_master_user_password = true`, default) with the
IMPL-0017 rotation surface, and `manage = false` is a guarded migration
escape hatch (INV-0008 F1) — the modules deliberately have **no password
input**. That is secure but inflexible: operators cannot pre-stage a
credential (e.g. for an app that reads the secret by a name it already
knows), cannot control the secret's name/path/KMS key/resource policy,
and cannot share one secret across resources. The requested capability
adds those degrees of freedom without regressing the
password-never-in-state property the managed path provides for free.

**Triggered by:** operator request following IMPL-0017; prior art
INV-0008, DESIGN-0010 (proxy secret composition), ADR-0020 (remote-state
key contract, for the producer-module alternative).

## Approach

1. Re-read the current credential surface in all three modules + proxy
   (`instance.tf` preconditions, `secret_rotation.tf`, proxy `iam.tf` /
   `locals.tf`, the proxy-composition outputs).
2. Verify — against the **actual pinned provider**, via
   `terraform providers schema -json`, not docs — that the write-only
   arguments and ephemeral resource types exist under `~> 6.2`.
3. Probe `terraform test` behavior empirically (throwaway module in
   `/tmp`, run 2026-08-11): ephemeral resources under `mock_provider`,
   `override_ephemeral` existence, and both password-generation options
   under the fleet's real-provider-fake-creds plan-suite pattern.
4. Desk-check the proxy contract, rotation, and lifecycle implications;
   fold the user-raised producer-module alternative into the analysis.

## Environment

| Component | Version / Value |
|-----------|----------------|
| Terraform CLI (mise pin) | 1.15.8 |
| AWS provider constraint / resolved | `~> 6.2` / 6.58.0 |
| Random provider (in-fleet precedent, s3 core) | `~> 3.7` |
| Module `required_version` (all RDS modules) | `>= 1.1` |
| LocalStack Community pin (apply tier) | 4.4 (Secrets Manager is Community-tier) |
| Probe workspace | `/tmp/eph-probe` (throwaway, deleted) |

## Findings

### F1 — Current state: three modes already exist, two of them implicit

The credential surface is identical across `instance`/`serverless`/
`cluster`: `manage_master_user_password` (default `true`) mints the
AWS-managed secret encrypted with `local.kms_key_arn`;
`master_secret_rotation_days` schedules service-managed rotation on it;
and the guardrail precondition (`manage || iam_auth`) makes
`manage = false` unusable except for IAM-auth or migration cases —
because **no password input exists**. So the fleet effectively has modes
"managed", "IAM-only", and "migration limbo". The requested capability
adds two real modes and should retire nothing: the managed default is
the correct posture for consumers with no opinion.

### F2 — The no-password-in-state mechanics exist and are verified in the pinned provider

Verified via `terraform providers schema -json` against aws provider
6.58.0 (what `~> 6.2` resolves to today):

| Surface | Present | `write_only` |
|---|---|---|
| `aws_db_instance.password_wo` (+ `password_wo_version`) | yes | yes |
| `aws_rds_cluster.master_password_wo` (+ `_version`) | yes | yes |
| `aws_secretsmanager_secret_version.secret_string_wo` (+ `_version`) | yes | yes |
| `ephemeral "aws_secretsmanager_secret_version"` (read) | yes | n/a |
| `ephemeral "aws_secretsmanager_random_password"` (generate) | yes | n/a |

Write-only arguments are never persisted to state or plan (verified in
the F3 probe: `secret_string_wo` evaluates as `null` in plan assertions
while its `_wo_version` integer is visible). Ephemeral resources are
opened during plan/apply and never stored. Together they satisfy
requirement (1) end-to-end: generate in memory → write to Secrets
Manager write-only → set on the DB write-only. The password exists in
exactly one durable place: the secret itself.

**Cost:** write-only arguments need Terraform ≥ 1.11 (ephemerals ≥
1.10), so the participating modules' `required_version = ">= 1.1"` must
rise to `">= 1.11"`. The repo CLI pin (1.15.8) already satisfies it;
this is a floor raise for external consumers only (OQ 6).

### F3 — Probed: what the test tiers can and cannot see

Empirical results (throwaway module: count-gated ephemeral →
`secret_string_wo`, Terraform 1.15.8):

1. **`mock_provider` cannot host ephemeral resource types at all.**
   `Error: No ephemeral resource types in mock providers` — and it fires
   at the *type* level: even a `count = 0` ephemeral of a mocked
   provider fails every run in the file. There is no
   `override_ephemeral` block ("Blocks of type "override_ephemeral" are
   not expected here"). Any module containing an
   `ephemeral "aws_secretsmanager_*"` block is untestable under
   `mock_provider "aws"`.
2. **This does not bite the RDS plan suites** — they use a real provider
   with fake creds + `skip_*` flags (not `mock_provider`; that pattern
   lives in the s3 family). Under the real-provider pattern a
   `count = 0` ephemeral is simply never opened.
3. **A local ephemeral is fully plan-testable.** With
   `ephemeral "random_password"` (random provider — opens locally, no
   API, no creds) feeding `secret_string_wo`, the exact fleet plan-suite
   provider block passes both the mode-ON and mode-OFF runs offline,
   including the assertion that the write-only value is `null` in plan.
4. **An AWS-API ephemeral is not plan-testable when ON.**
   `aws_secretsmanager_random_password` and the reference-mode read
   (`ephemeral "aws_secretsmanager_secret_version"`) perform a real API
   call during plan — the same class of behavior as the s3 tri-state
   data-source gotcha (a variable-validation failure does not
   short-circuit evaluation). Plan suites must keep reference mode OFF
   in every run; its live coverage belongs to the LocalStack apply tier,
   where it is cheap — Secrets Manager is Community-tier, so
   `serverless`'s existing Community apply suite can carry it.

Consequence: **create-mode generation should use the random provider's
local ephemeral, not the AWS one** — testability decides what upstream
capability alone cannot (OQ 3). The fleet already ships
`random ~> 3.7` in the s3 core, so this is a second use, not a new
dependency class.

### F4 — Password lifecycle is version-gated, in both directions

Ephemeral values are re-opened (→ regenerated) on **every** operation;
what prevents a new password every apply is that write-only arguments
are only *sent* when their `*_wo_version` integer changes. The correct
wiring is one module variable (e.g. `master_password_version`, number,
default `1`) feeding both `secret_string_wo_version` and
`password_wo_version`/`master_password_wo_version`: bump it → one new
password is generated in memory and lands in the secret and the DB in
the same apply; leave it → nothing is sent, the credential is stable.
Rotation in create mode is therefore "bump an integer."

The sharp edge is reference mode: **rotating the referenced secret in
Secrets Manager does not propagate to the DB on the next apply** unless
the operator also bumps the version variable (SM version ids are UUIDs
and cannot feed the integer). This must be documented loudly — it is
the mirror image of the managed path, where RDS rotates the DB and the
secret atomically and Terraform sees nothing.

### F5 — Proxy composition survives untouched if the output contract is reused

`rds/proxy` consumes exactly two secret facts from the target's remote
state: `master_user_secret_arn` (IAM `GetSecretValue` scope + proxy
auth) and `master_user_secret_kms_key_arn` (`kms:Decrypt` scope). If
the target modules emit the **customer-managed** secret's ARN/KMS ARN
under those same output names in create/reference modes, the proxy
composes with all three modes with zero changes — the V5 fail-closed
precondition keeps rejecting the no-secret path automatically.

Two contract obligations transfer to the new modes:

- **Secret shape.** RDS Proxy requires the secret value to be the
  RDS-format JSON `{"username": ..., "password": ...}`. Create mode
  must write `jsonencode({username, password})`, not a bare password
  string. In reference mode the module *cannot verify* the shape at
  plan (the value is never material to Terraform) — an operator
  contract to document in the README, not a precondition.
- **KMS.** In reference mode the secret's CMK ARN is not derivable from
  the ARN alone; a companion input (or a null → `aws/secretsmanager`
  convention mirroring the proxy's existing `ViaService`-fenced
  fallback) must feed the `master_user_secret_kms_key_arn` output.

### F6 — Rotation is the one thing customer-managed secrets lose

RDS service-managed rotation (what `master_secret_rotation_days`
schedules) exists **only** for the RDS-managed master secret. A
customer-managed secret rotates via a rotation Lambda; AWS's hosted
rotation functions are CloudFormation/SAM-only (`HostedRotationLambda`),
so Terraform users deploy the aws-samples rotation function themselves —
a Lambda + networking + IAM footprint this fleet does not have and
should not grow inside an RDS module. In the new modes the honest v1
posture is: create mode rotates by version-bump applies (F4), reference
mode's rotation belongs to whoever owns the secret, and
`master_secret_rotation_days` gains a precondition restricting it to the
managed mode (OQ 4).

### F7 — The producer-module option is orthogonal, not competing

The suggested `modules/secretsmanager/secret` producer publishing at an
ADR-0020 key (shape `secrets`, e.g.
`<account_name>/<region>/secrets/<name>/terraform.tfstate`) composes
*through* reference mode rather than replacing it — provided one hard
rule: the producer's remote-state outputs carry the **pointer only**
(secret ARN, name, KMS key ARN), never the value. (Remote-state outputs
are re-persisted into every consumer's state — a value output would leak
the password into N+1 state files.) The consumer flow is then: read ARN
from producer state → ephemeral `GetSecretValue` at apply → write-only
password. Since reference mode takes an ARN, where the ARN comes from —
a literal variable or a remote-state read — is a consumer-side detail.
A full ARN also carries account and region, so cross-account/cross-region
secrets work via SM resource policies + KMS grants with no extra module
surface. The producer module is real future work (resource policy,
replica regions, CMK) but is **not required** to ship either requested
capability.

## Conclusion

**Answer: Yes.** Both requirements are satisfiable inside the existing
three modules with ephemeral resources + write-only arguments, with the
password durable only in Secrets Manager — never in state, plan, or
code. The mechanics are verified present in the pinned provider (F2) and
empirically compatible with the fleet's plan-suite pattern, with two
binding constraints discovered by probe: `mock_provider` cannot coexist
with ephemeral resources (F3.1 — irrelevant to RDS suites, fatal if this
pattern ever migrates into the s3 family's mock-based suites), and
create-mode generation must be the random provider's local ephemeral for
the plan tier to see the mode at all (F3.3/3.4). The proxy contract
survives by output-name reuse (F5); rotation is the only capability
regression and has an honest v1 answer (F6); the producer-module idea
layers cleanly on top later (F7).

## Recommendation

Proceed to a DESIGN doc once the open questions below are decided.
Suggested shape (contingent on OQ answers): a tri-state master-password
mode on `instance`/`serverless`/`cluster` — `managed` (default,
today's behavior, rotation surface intact), `create` (module-owned
secret, ephemeral `random_password` → `secret_string_wo` +
`password_wo`, RDS-format JSON, version-gated), `reference` (ARN in,
ephemeral read → `password_wo`) — the INV-0008 guardrail generalized to
"exactly one authentication path", the proxy-composition outputs
carrying whichever secret is authoritative, plan gates asserting
create-mode ON/OFF + all preconditions, and the live apply proof riding
`serverless`'s Community suite (Secrets Manager needs no Pro tier).

## Open Questions

### 1. What is the overall architecture?

- **a. (Recommended)** Extend the three secret-owning RDS modules with
  the tri-state mode (`managed` / `create` / `reference`); build no new
  module now. Reference mode takes a secret ARN, so a future
  `modules/secretsmanager/secret` producer (F7) composes through it
  without touching the RDS modules again — the ADR-0020 `secrets` shape
  gets reserved when that module lands.
- b. Build the standalone Secrets Manager producer module first and give
  the RDS modules only a remote-state-composed reference mode (no
  in-module create). Purest Gruntwork layering, but day-one users must
  stand up two stacks for what (a) does in one, and the pointer-vs-value
  discipline (F7) must be designed immediately.
- c. Both at once: tri-state modules + producer module in one effort.
  Maximum capability, largest blast radius for one design.
- Other: (your call)

### 2. What variable surface expresses the mode?

- **a. (Recommended)** One typed object, e.g.
  `master_password = { mode = "managed" | "create" | "reference", secret_arn = ..., secret_kms_key_arn = ..., version = 1 }`
  with `optional()` members, defaulting to `{ mode = "managed" }` —
  the s3 `access_logging` tri-state precedent. Cross-member rules
  (reference requires `secret_arn`; `secret_arn` forbidden otherwise)
  live in one variable validation; the INV-0008 guardrail precondition
  generalizes to "managed, create, reference, or IAM auth — pick one".
  `manage_master_user_password` becomes derived (`mode == "managed"`),
  kept as a deprecated passthrough for one release or removed per OQ 6.
- b. Flat variables (`create_master_secret` bool,
  `master_password_secret_arn` string, `master_password_version`
  number) + cross-variable preconditions. Smaller diff against today's
  surface, but the illegal-combination matrix lives in prose across
  three variables instead of one validation.
- Other: (your call)

### 3. How is the password generated in create mode?

- **a. (Recommended)** `ephemeral "random_password"` (random provider
  `~> 3.7`, already in-fleet via the s3 core). Opens locally with no
  API call, which is precisely what makes create mode assertable in the
  offline plan suites (F3.3); exclusions/length exposed as tame
  variables.
- b. `ephemeral "aws_secretsmanager_random_password"` (SM
  `GetRandomPassword`). No new provider in the RDS modules, but it makes
  create-mode ON un-plannable offline (F3.4), shrinking the plan gate to
  OFF-path-only — and it is unmockable forever if a suite ever adopts
  `mock_provider`.
- c. Operator supplies the password out-of-band (CLI mint à la
  `bedrock-keyctl`, module only references). Strongest separation, but
  it silently reduces requirement (1) to requirement (2) and adds a
  tooling dependency to a Terraform-only flow.
- Other: (your call)

### 4. What happens to rotation in the customer-managed modes?

- **a. (Recommended)** v1 ships none: create mode rotates by bumping
  `version` (one apply = new password in secret + DB, F4); reference
  mode's rotation belongs to the secret's owner, with the
  does-not-auto-propagate caveat (F4) documented loudly.
  `master_secret_rotation_days` gains a precondition restricting it to
  `mode = "managed"`. Honest about F6 instead of hiding a Lambda inside
  an RDS module.
- b. Accept an optional operator-supplied `rotation_lambda_arn` and wire
  `aws_secretsmanager_secret_rotation` to it in create mode. Flexible,
  but the module can't validate the Lambda actually implements the RDS
  rotation contract — failure surfaces at rotation time, not plan time.
- c. Build a companion rotation-Lambda module (new fleet scope: Lambda
  packaging, VPC access to the DB, IAM). Defer to its own INV if wanted.
- Other: (your call)

### 5. How are create-mode secret naming and deletion handled?

- **a. (Recommended)** `name_prefix = "<identifier_prefix>-master-"`
  (SM name-reuse is blocked for the length of the recovery window, so
  an exact name would brick recreate-after-destroy for up to 30 days),
  plus `secret_recovery_window_days` (number, default `30`, `0` =
  immediate deletion) — apply-tier teardown sets `0` the same way the
  Pro suites already set `deletion_protection = false` /
  `skip_final_snapshot = true`.
- b. Exact `secret_name` variable (operators with naming standards get
  determinism, and accept the recreate-collision window as their
  problem). Could also be layered onto (a) as an optional override.
- Other: (your call)

### 6. How is the `required_version` floor raise rolled out?

- **a. (Recommended)** Raise `required_version` to `>= 1.11` only in
  the three modules that gain write-only arguments, in the same minor
  release that ships the feature, called out in release notes.
  Terraform 1.11 shipped February 2025; anyone below it keeps working
  on the prior tag (per-module semver exists for exactly this).
- b. Fleet-wide floor raise to `>= 1.11` for uniformity. One consistent
  floor, but forces the constraint on modules that gain nothing.
- c. Gate the new modes on a capability check and keep `>= 1.1`.
  Not actually possible — `*_wo` arguments are parse-time surface, not
  runtime-conditional; listed only to record why it's out.
- Other: (your call)

## References

- INV-0008 — RDS managed master secret rotation schedule and
  manage-false guardrails (the `manage || iam_auth` precondition this
  design generalizes)
- IMPL-0017 — master-secret rotation + guardrail implementation
  (`secret_rotation.tf` in all three modules)
- DESIGN-0010 — RDS Proxy composition (secret consumption contract,
  V1–V7 validations)
- ADR-0020 — remote-state key contract (the `secrets` shape the F7
  producer would reserve)
- `modules/rds/instance/instance.tf` (guardrail precondition),
  `modules/rds/instance/secret_rotation.tf`,
  `modules/rds/proxy/iam.tf`, `modules/rds/proxy/locals.tf`,
  `modules/rds/instance/outputs.tf` (proxy-composition outputs)
- Terraform: ephemeral resources (≥ 1.10), write-only arguments
  (≥ 1.11) — verified against aws provider 6.58.0 via
  `terraform providers schema -json`, 2026-08-11
- Probe transcript summary (2026-08-11, `/tmp/eph-probe`, deleted):
  `mock_provider` + ephemeral → type-level error; `override_ephemeral`
  → does not exist; `random_password` ephemeral + `secret_string_wo`
  under real-provider-fake-creds → ON and OFF runs pass offline,
  write-only value asserts as `null` in plan
