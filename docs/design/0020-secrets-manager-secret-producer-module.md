---
id: DESIGN-0020
title: "Secrets Manager secret producer module"
status: Implemented
author: Donald Gifford
created: 2026-08-11
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0020: Secrets Manager secret producer module

**Status:** Implemented
**Author:** Donald Gifford
**Date:** 2026-08-11

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module layout](#module-layout)
  - [The password path (the invariant)](#the-password-path-the-invariant)
  - [Variable surface](#variable-surface)
  - [Secret naming and deletion](#secret-naming-and-deletion)
  - [Version-gated writes and rotation](#version-gated-writes-and-rotation)
  - [KMS posture](#kms-posture)
  - [Cross-account reads](#cross-account-reads)
  - [Outputs — pointer-only, enforced](#outputs--pointer-only-enforced)
  - [Remote-state key contract](#remote-state-key-contract)
  - [CI mechanics](#ci-mechanics)
- [Testing Strategy](#testing-strategy)
- [Follow-up work: the RDS reference mode](#follow-up-work-the-rds-reference-mode)
- [Phases](#phases)
  - [Phase 1: Module core](#phase-1-module-core)
  - [Phase 2: Cross-account surface and hardening](#phase-2-cross-account-surface-and-hardening)
  - [Phase 3: LocalStack Community apply suite](#phase-3-localstack-community-apply-suite)
  - [Phase 4: Contract and doc closure](#phase-4-contract-and-doc-closure)
- [Open Questions](#open-questions)
  - [1. What secret content shapes does v1 support?](#1-what-secret-content-shapes-does-v1-support)
  - [2. What is the KMS default?](#2-what-is-the-kms-default)
  - [3. What shape does the cross-account read surface take?](#3-what-shape-does-the-cross-account-read-surface-take)
  - [4. Are multi-region replicas in v1?](#4-are-multi-region-replicas-in-v1)
  - [5. What are the generated-password defaults?](#5-what-are-the-generated-password-defaults)
  - [6. How deep does the apply suite verify the secret?](#6-how-deep-does-the-apply-suite-verify-the-secret)
- [References](#references)
<!--toc:end-->

## Overview

`modules/secretsmanager/secret` is the fleet's Secrets Manager secret
producer: it creates a customer-managed secret whose value — a generated
password, alone or wrapped in DB-credentials JSON — **never exists in
Terraform state, plan output, or code**. It is the INV-0010 resolution
1b architecture: the producer owns secret creation (INV-0010
requirement 1), and the secret-owning RDS modules later gain only a
remote-state-composed *reference* mode (requirement 2, a follow-up to
this design — see [Follow-up work](#follow-up-work-the-rds-reference-mode)).
The no-value-anywhere property comes from the ephemeral + write-only
mechanics verified in INV-0010 F2/F3: `ephemeral "random_password"`
(opens locally, plan-testable offline) feeding
`aws_secretsmanager_secret_version.secret_string_wo` (write-only, never
persisted), gated by an operator-bumped version integer.

The `secretsmanager/secret/` sub-directory leaves room for siblings
(e.g. `secretsmanager/rotation-lambda/` if INV-0010 OQ 4c is ever
revisited).

## Goals and Non-Goals

### Goals

- One module that creates an SM secret + initial version with a
  generated value, with the value durable in exactly one place: the
  secret itself (INV-0010 F2).
- DB-credentials content shape compatible with the RDS-format JSON
  (`{"username": ..., "password": ...}`) that `rds/proxy` requires of
  any secret it fronts (INV-0010 F5).
- Deterministic, version-gated writes: an unchanged config re-applies
  as a no-op; rotation is "bump an integer" (INV-0010 F4, resolution
  4a).
- Publish the ADR-0020 pointer contract (`secrets` shape) so the RDS
  reference mode — and any future consumer — composes via remote state
  with **pointer-only** outputs (INV-0010 F7).
- Fully green plan suite exercising the generation path itself, per the
  INV-0010 F3.3 probe (the local ephemeral is plan-testable offline).
- Community-tier LocalStack apply proof (Secrets Manager needs no Pro).

### Non-Goals

- **Rotation.** No rotation Lambda, no
  `aws_secretsmanager_secret_rotation` (INV-0010 F6 / resolution 4a).
  Rotation is a version-bump apply; a rotation-lambda sibling is its
  own future investigation.
- **The RDS module changes.** Reference mode, the two-state
  `master_password` object (2a), the `required_version` raise in the
  RDS modules (6a), and the proxy output rewiring are follow-up work
  tracked below — not this design's scope.
- **Arbitrary caller-supplied secret values.** v1 generates; it does
  not accept a value input (see OQ 1 for the ephemeral-variable
  option's disposition).
- **Kubernetes-facing secret distribution** — out of scope per the
  fleet's AWS-API-only rule; consumers read SM directly.

## Background

INV-0010 concluded (all findings referenced here live in that doc):

- The pinned provider (6.58.0 under `~> 6.2`) ships every needed
  surface: `secret_string_wo` (+ `_version`) on
  `aws_secretsmanager_secret_version`, and the ephemeral resource types
  (F2). Write-only arguments require `required_version = ">= 1.11"` —
  this module is the fleet's first to carry that floor (resolution 6a;
  the CLI pin 1.15.8 already satisfies it).
- `mock_provider` rejects ephemeral resource *types* outright, and
  `override_ephemeral` does not exist (F3.1/3.2). **This module's test
  suites must use the real-provider-fake-creds pattern** (the RDS
  convention), never the s3 family's `mock_provider` pattern — a
  standing constraint recorded in the module README.
- Generation must be the random provider's local ephemeral
  (`ephemeral "random_password"`, resolution 3a): it opens without an
  API call, which is what makes the generation path assertable in the
  offline plan tier (F3.3). The AWS-API alternative
  (`aws_secretsmanager_random_password`) is unmockable and breaks
  offline plans (F3.4).
- Write-only values are provably absent from plan: the F3 probe
  asserted `secret_string_wo == null` in a passing plan run while its
  companion `_wo_version` integer stayed visible — the plan suite here
  bakes that exact assertion in as the no-leak gate.
- Remote-state outputs re-persist into every consumer's state, so the
  producer's outputs must be the pointer (ARN / name / KMS ARN), never
  the value (F7).

Prior art: `network/vpc-lookup` (producer-of-a-contract precedent),
ADR-0020 (key contract this design extends with the `secrets` shape),
IMPL-0017 (the managed-secret rotation surface that stays the RDS
default), DESIGN-0010 (proxy secret consumption this module must stay
compatible with).

## Detailed Design

### Module layout

```text
modules/secretsmanager/secret/
├── main.tf              # aws_secretsmanager_secret + version + ephemeral
├── policy.tf            # optional resource policy (cross-account reads)
├── variables.tf
├── outputs.tf
├── versions.tf          # required_version ">= 1.11"; aws ~> 6.2; random ~> 3.7
├── .tflint.hcl
├── README.md            # + "Remote-state key contract" section
├── USAGE.md
├── tests/               # plan suite (the gate)
└── tests-localstack/    # Community apply suite + FINDINGS.md
```

`versions.tf` is the fleet's first `required_version = ">= 1.11"` — a
comment explains *why* (write-only arguments), so the floor is never
"simplified" back down.

### The password path (the invariant)

```hcl
ephemeral "random_password" "this" {
  length           = var.password_length
  special          = true
  override_special = var.password_override_special
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id

  secret_string_wo = var.username != null ? jsonencode({
    username = var.username
    password = ephemeral.random_password.this.result
  }) : ephemeral.random_password.this.result

  secret_string_wo_version = var.secret_string_version
}
```

(Exact shape-selection mechanics per OQ 1.) The value's entire
lifecycle: generated in memory during the operation → sent write-only →
durable only in Secrets Manager. Nothing else in the module may
reference `ephemeral.random_password.this.result` — that is a review
invariant, and the plan suite's `secret_string_wo == null` assertion is
its mechanical backstop.

### Variable surface

Core (names final, details per OQs):

- `name` (string, required) — seeds `name_prefix` and is the ADR-0020
  triple-coupled identifier (producer `name` == live-repo folder ==
  consumer input). Charset validation mirrors the fleet norm.
- `username` (string or null per OQ 1) — selects/feeds the
  DB-credentials JSON shape.
- `secret_string_version` (number, default `1`, validation `>= 1`) —
  the F4 version gate; bumping it is the rotation action.
- `password_length` / `password_override_special` (OQ 5 defaults).
- `secret_recovery_window_days` (number, default `30`, validation
  `0 or 7–30` — the AWS API constraint) — `0` is the test-teardown and
  break-glass path (resolution 5a).
- `kms_key_arn` (OQ 2).
- `read_principals` or equivalent (OQ 3).
- `description`, `tags` — the usual.

Terragrunt globals: none required for the module itself (it reads no
remote state); the apply fixture threads the shared
`terragrunt-inputs.tfvars` globals only for seeding its own state
object, mirroring `reference-vpc`.

### Secret naming and deletion

Resolution 5a: `name_prefix = "${var.name}-"` on
`aws_secretsmanager_secret`, because Secrets Manager blocks name reuse
for the length of the recovery window — an exact `name` would brick
recreate-after-destroy for up to 30 days. The random suffix AWS
appends is harmless to consumers: they resolve the secret by ARN from
remote state, never by constructing the name. (The ADR-0020 `<name>`
coupling is about the **state key**, not the SM secret name — the
README says this explicitly.)

`recovery_window_in_days = var.secret_recovery_window_days` rides the
resource; the apply suite passes `0` so `terraform test` teardown
actually deletes (same posture as the Pro suites'
`deletion_protection = false`).

### Version-gated writes and rotation

INV-0010 F4, applied: ephemeral values regenerate on **every**
operation, and what keeps the secret stable is that write-only
arguments are only *sent* when `secret_string_wo_version` changes. So:

- Steady state: applies are no-ops; the regenerated in-memory password
  is discarded unsent.
- Rotation: bump `secret_string_version` → one new password lands in
  the secret in that apply.
- The README documents the RDS-side half of the story ahead of the
  follow-up: consumers referencing this secret must re-send their own
  write-only password (their own version bump) to pick up the new
  value — rotation does **not** auto-propagate (F4's sharp edge).

### KMS posture

Resolved (OQ 2, Other): **the AWS-managed `aws/secretsmanager` key is
the default; BYO CMK overrides; null is what the pointer reports for
the managed case.** Concretely: `kms_key_arn` (string, default `null`);
when null the resource's `kms_key_id` is left unset so Secrets Manager
uses `aws/secretsmanager`, and the module's `kms_key_arn` **output** is
null; when set, the CMK ARN rides the resource and the output
faithfully echoes it. The output contract matters because the proxy's
IAM composer keys off it: a non-null ARN gets exact `kms:Decrypt`
scoping, null falls back to the existing `ViaService`-fenced wildcard
(INV-0010 F5, `modules/rds/proxy/iam.tf`). Documented caveat:
cross-account reads require the BYO CMK path (OQ 3 interaction below).

### Cross-account reads

Resolved (OQ 3a): typed `read_principals` (list of IAM principal ARNs,
default `[]` → no policy resource at all, count-gated). The module
composes an `aws_secretsmanager_secret_policy` granting
`GetSecretValue` / `DescribeSecret` to exactly those principals;
validation rejects `*`. A raw `policy_json` passthrough (OQ 3b) is
**explicitly deferred** to follow-up work, not rejected. Documented
caveats: a CMK-encrypted secret **also** needs a key-policy grant the
module does not own — and cross-account with the AWS-managed
`aws/secretsmanager` key does not work at all (AWS restriction), which
the README must state to head off a confusing `AccessDenied`.

### Outputs — pointer-only, enforced

```text
secret_arn            — the composition pointer (consumer IAM scope + read target)
secret_id             — resource id (== ARN for SM; kept for symmetry)
secret_name           — the actual (suffixed) name, informational
kms_key_arn           — null ⇒ aws/secretsmanager managed key (proxy wildcard path)
secret_string_version — the current version-gate integer, informational
username              — non-secret half of the credential pair (null in bare mode)
```

**Never the value.** INV-0010 F7's rule is structural here: no output
may reference the ephemeral or any value-bearing attribute (when only
`secret_string_wo` is used there is no readable `secret_string`
attribute — the provider enforces half of this for us). The plan suite
asserts the output *set* is exactly the contract list, which doubles as
drift protection for the RDS follow-up.

### Remote-state key contract

ADR-0020 gains the `secrets` shape:

```text
<account_name>/<region>/secrets/<name>/terraform.tfstate
```

- Producer: this module, via the live repo's folder layout (the key
  itself is Terragrunt's, as always).
- First consumer: the RDS modules' reference mode (follow-up) — reads
  `secret_arn` + `kms_key_arn` (+ `username` for operator sanity
  checks), composes the key from its own `master_password` object's
  stack-name member, carries the standard `assume_role` block.
- `<name>` is triple-coupled: producer `var.name` == live-repo folder
  == consumer input. The module README gets the standard "Remote-state
  key contract" section now; the ADR-0020 consumer table gains the RDS
  row when the follow-up lands (the shape row lands in Phase 4).

### CI mechanics

Nothing bespoke: `scripts/changed-modules.sh` discovers leaf modules by
`*.tf` presence and derives tiers from test-directory existence, so
`secretsmanager/secret` enters the plan matrix automatically and the
`tests-localstack/` dir enrolls it in the Community apply tier. Phase 1
verifies this with `just changed` rather than assuming it. The static
gate picks the module up the same way (`just static` iterates
discovered modules).

## Testing Strategy

Two tiers, both using the **real-provider-fake-creds** pattern (the
INV-0010 F3.1 constraint — `mock_provider` is structurally incompatible
with this module, recorded in the README and test-file comments):

**Plan suite (`tests/`, the gate).** Unusually strong for this fleet
because generation is local (F3.3):

- The no-leak gate: a passing plan asserting
  `aws_secretsmanager_secret_version.this.secret_string_wo == null`
  AND `secret_string_wo_version == var.secret_string_version` — the
  INV-0010 probe assertion, baked in permanently.
- Naming: `name_prefix` composition, charset validation
  (`expect_failures`), description/tags passthrough.
- Recovery window: default 30, `0` accepted, `1–6` rejected
  (`expect_failures` on the validation).
- Version gate: `secret_string_version = 0` rejected; a bump reflected
  in the plan.
- Content shape selection per OQ 1 (all modes planned).
- KMS + policy wiring per the OQ 2/3 answers (policy on/off shapes).
- Output-contract assertion (the pointer-only set, by name).

**Community apply suite (`tests-localstack/`).** Token-free
`localstack/localstack:4.4`, `SERVICES=secretsmanager,sts` — Secrets
Manager is Community-tier (INV-0010 environment note). Applies the
module, asserts the pointer outputs are real ARNs, verification depth
per OQ 6, teardown via `secret_recovery_window_days = 0`. FINDINGS.md
records LocalStack parity observations (e.g. whether name-reuse
blocking during the recovery window is emulated — expected not; worth
one probe line).

No Pro tier: nothing here needs it.

## Follow-up work: the RDS reference mode

Explicitly out of scope here; recorded so the thread from INV-0010
resolution 1b is unbroken. After this module lands:

1. **RDS reference mode** (`instance` / `serverless` / `cluster`): the
   two-state `master_password` object (INV-0010 resolution 2a —
   `managed` default / `reference`), a count-gated
   `data.terraform_remote_state.master_secret` read at the ADR-0020
   `secrets` key, `ephemeral "aws_secretsmanager_secret_version"` →
   `password_wo` / `master_password_wo` + version gate, the INV-0008
   guardrail generalized to "managed, reference, or IAM auth", and
   `required_version >= 1.11` in the three modules (resolution 6a).
   Plan suites stub the pointer read via `override_data` with reference
   OFF (F3.4); the live proof rides `serverless`'s Community apply with
   this module as its fixture.
2. **Proxy contract continuity**: the three modules emit the referenced
   secret's ARN/KMS ARN under the existing `master_user_secret_arn` /
   `master_user_secret_kms_key_arn` output names so `rds/proxy`
   composes unchanged (INV-0010 F5); its README gains the RDS-format
   JSON shape note pointing at this module's `username` mode.
3. **ADR-0020**: add the RDS consumer row under the `secrets` shape.
4. **Deferred/optional**: rotation-lambda sibling INV (INV-0010 OQ 4c),
   BYO-value mode via ephemeral variables (OQ 1 resolution defers it),
   multi-region replicas (OQ 4a defers them), and the raw `policy_json`
   passthrough (OQ 3 resolution defers it).

## Phases

### Phase 1: Module core

Tasks:

- [ ] Scaffold `modules/secretsmanager/secret` (versions.tf with
      `required_version = ">= 1.11"` + why-comment, aws `~> 6.2`,
      random `~> 3.7`; `.tflint.hcl` at ruleset-aws 0.48.0; README
      skeleton noting the mock_provider incompatibility)
- [ ] Core resources: `aws_secretsmanager_secret` (name_prefix,
      recovery window, kms per OQ 2, tags),
      `ephemeral "random_password"` (OQ 5 defaults),
      `aws_secretsmanager_secret_version` with `secret_string_wo` +
      `secret_string_wo_version` (content shape per OQ 1)
- [ ] Validations: name charset, recovery window `0 or 7–30`,
      `secret_string_version >= 1`, OQ-1 shape rules
- [ ] Pointer-only outputs (contract set above)
- [ ] Plan suite per Testing Strategy (real-provider pattern; no-leak
      gate; validations via `expect_failures`)
- [ ] Verify CI pickup: `just changed` lists the module at the plan
      tier from a seeded diff
- [ ] `just tf docs` USAGE.md; conventional commit

Success criteria:

- `just tf validate|fmt|lint|test secretsmanager/secret` all green
- Plan suite includes the passing `secret_string_wo == null` assertion
- `just static` green repo-wide

### Phase 2: Cross-account surface and hardening

Tasks:

- [ ] `policy.tf`: resource policy per OQ 3 (count-gated — no policy
      resource when unused), with the CMK-vs-managed-key cross-account
      caveat in README
- [ ] Replicas per OQ 4 (implement, or record the deferral in README)
- [ ] Plan suite additions: policy on/off shapes, principal validation,
      OQ-4 surface if in scope
- [ ] README "Remote-state key contract" section (`secrets` shape,
      triple-coupling, pointer-only rule, rotation
      does-not-auto-propagate caveat)

Success criteria:

- Plan suite green including the new shapes; `just static` green

### Phase 3: LocalStack Community apply suite

Tasks:

- [ ] `tests-localstack/` apply run(s): real ARN outputs, OQ-6
      verification depth, teardown with
      `secret_recovery_window_days = 0`
- [ ] FINDINGS.md: LocalStack parity notes (name-reuse blocking probe;
      anything OQ 6 surfaces)
- [ ] Run live against token-free `localstack/localstack:4.4`
      (`SERVICES=secretsmanager,sts`) — suite passing

Success criteria:

- `just tf test-localstack secretsmanager/secret` green against a live
  Community container; `just changed` shows the module in the
  community tier

### Phase 4: Contract and doc closure

Tasks:

- [ ] ADR-0020: add the `secrets` shape row (+ reserved consumer-row
      placeholder for the RDS follow-up)
- [ ] CLAUDE.md: new `modules/secretsmanager/` section (module posture,
      the 1.11 floor, the mock_provider constraint, test tiers)
- [ ] INV-0010: note the producer half of resolution 1b delivered
      (pointer to this design + the module)
- [ ] `docz update` for indexes (restore known TOC mangling); root
      README module table rides the release automation
- [ ] Conventional commits; PR labeled `minor` (new module)

Success criteria:

- `just static` + full plan matrix green in CI; ADR-0020 and the module
  README agree on the key shape verbatim
- The Follow-up section above is reflected in CLAUDE.md as the next
  piece of work so the RDS design picks up with zero re-derivation

## Open Questions

> **Resolved 2026-08-11: 1a, 2 Other, 3a (+ explicit deferral), 4a,
> 5a, 6a.** OQ 2's resolution in the operator's words: "default to the
> aws managed key — aws/secretsmanager key, then byo, then null" —
> i.e. the managed key is the default, a BYO CMK overrides it, and
> null is what the `kms_key_arn` pointer output reports in the managed
> case (the proxy's `ViaService` wildcard path). OQ 3 resolves to the
> typed `read_principals` surface with the raw `policy_json`
> passthrough (3b) explicitly deferred to follow-up work rather than
> rejected. The Detailed Design sections above are updated to the
> resolved semantics; deferrals are tracked in
> [Follow-up work item 4](#follow-up-work-the-rds-reference-mode).

### 1. What secret content shapes does v1 support?

**Resolved: a.**

- **a. (Recommended)** Two, selected by `username`: set → the
  RDS-format JSON `{"username", "password"}` (what `rds/proxy` requires
  and the RDS follow-up consumes, INV-0010 F5); null → the bare
  generated password string (generic consumers). One variable doubles
  as the mode switch — no enum to keep in sync — and both paths stay
  fully plan-testable. BYO-caller-value via ephemeral input variables
  is explicitly deferred (needs its own `terraform test` behavior
  probe; recorded in Follow-up 4).
- b. DB-credentials JSON only (`username` required). Purpose-built and
  smallest, but the first non-DB consumer forces a v2 surface change on
  a security-sensitive module.
- c. Also accept a caller-supplied value now via an ephemeral input
  variable feeding `secret_string_wo`. Most capable, but ephemeral
  variables are un-probed in this fleet's test harness and widen the
  no-leak review surface in v1.
- Other: (your call)

### 2. What is the KMS default?

**Resolved: Other — managed key default, BYO override, null output for managed (see note above).**

- **a. (Recommended)** BYO `kms_key_arn`, default `null` → the
  AWS-managed `aws/secretsmanager` key. Zero marginal cost, zero
  key-management scope, and the null case is already first-class
  downstream (the proxy's `ViaService`-fenced wildcard path exists
  precisely for it). The output contract reports null faithfully.
  Documented caveat: cross-account reads require a CMK (OQ 3
  interaction).
- b. Module-managed CMK by default with BYO override — the RDS
  modules' `kms.tf` precedent: plan-knowable ARN and exact proxy
  scoping always, at ~$1/month per secret plus key lifecycle (deletion
  window, key policy) on every instantiation.
- c. Require `kms_key_arn` (fail-closed, no default). Strictest, but
  makes the simple same-account case needlessly heavy.
- Other: (your call)

### 3. What shape does the cross-account read surface take?

**Resolved: a, with 3b explicitly deferred.**

- **a. (Recommended)** Typed `read_principals` (list of IAM principal
  ARNs, default `[]` → no policy resource at all, count-gated like the
  fleet's other optional resources). The module composes the
  `GetSecretValue`/`DescribeSecret` grant; validation rejects `*`.
  Covers the stated need ("account or whatever") with a small,
  auditable surface.
- b. Raw `policy_json` passthrough — maximum flexibility, no
  guardrails; the module cannot reject a public-read footgun.
- c. Defer entirely (same-account only in v1). Smallest, but
  cross-account was named in the original ask, and retrofitting a
  policy later touches a live secret.
- Other: (your call)

### 4. Are multi-region replicas in v1?

**Resolved: a.**

- **a. (Recommended)** No — defer. The first consumer (RDS reference
  mode) is same-region by construction, `replica` blocks bring
  per-region KMS decisions with them, and adding replicas later is
  additive (no destroy). README records the deferral.
- b. Optional `replica_regions` list now (each entry optionally
  carrying its own KMS ARN). Complete, but ships unconsumed complexity
  on day one.
- Other: (your call)

### 5. What are the generated-password defaults?

**Resolved: a.**

- **a. (Recommended)** `password_length = 32`,
  `override_special = "!#$%&*()-_=+[]{}<>:?"` — the RDS-legal set
  (master passwords for postgres/mysql forbid `/`, `@`, `"`, and
  space), so the DB-credentials mode works out of the box for both
  engines; both variables overridable, length validated `>= 16`.
- b. Full printable-special default (SM `GetRandomPassword` parity),
  operators exclude per-consumer. Maximally random, but the primary
  consumer would need the exclusion boilerplate at every call site.
- Other: (your call)

### 6. How deep does the apply suite verify the secret?

**Resolved: a.**

- **a. (Recommended)** Metadata-only: secret exists, ARN/name/KMS
  outputs are real, a current version exists (via the
  `aws_secretsmanager_secret` data source — no value access). The
  value never enters even the transient test state, keeping "no value
  outside SM, ever" grep-provable across the repo; the JSON shape is
  guaranteed by construction (`jsonencode`) and asserted at plan.
- b. Also read the value back in the apply suite
  (data `aws_secretsmanager_secret_version` against LocalStack) to
  assert the JSON keys end to end. Proves shape live, but puts a
  (fake, throwaway) secret value into the test run's state and breaks
  the repo-wide invariant's greppability for marginal signal.
- Other: (your call)

## References

- **INV-0010** — RDS master password via customer-managed Secrets
  Manager secrets
  (`docs/investigation/0010-rds-master-password-via-customer-managed-secrets-manager-secrets.md`):
  the resolutions this design implements (1b producer-first, 3a local
  ephemeral, 4a no-rotation v1, 5a name_prefix + recovery window, 6a
  `>= 1.11` floor) and the F2–F7 provider/test-harness evidence; the
  RDS-side resolutions (2a, 6a) land in the follow-up.
- INV-0008 / IMPL-0017 — the managed-master-secret default and rotation
  surface that remains the RDS default posture.
- DESIGN-0010 — RDS Proxy composition; the RDS-format JSON shape and
  the `ViaService`-fenced KMS fallback this module's contract respects.
- ADR-0020 — remote-state key contract; gains the `secrets` shape in
  Phase 4.
- `test/fixtures/terragrunt-inputs.tfvars` (INV-0005 / IMPL-0015) — the
  shared globals the apply fixture threads for state seeding.
- `modules/network/vpc-lookup` — producer-module precedent
  (contract-first, README key-contract section).
- [Follow-up work: the RDS reference mode](#follow-up-work-the-rds-reference-mode)
  — the reference-mode design/impl picks up there after this module
  lands.
