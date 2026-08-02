---
id: DESIGN-0019
title: "S3 module family internal core and initial bucket modules"
status: Approved
author: Donald Gifford
created: 2026-08-02
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0019: S3 module family internal core and initial bucket modules

**Status:** Approved
**Author:** Donald Gifford
**Date:** 2026-08-02

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Family layout and the nesting exemption](#family-layout-and-the-nesting-exemption)
  - [The internal core interface](#the-internal-core-interface)
  - [Naming and the shard prefix](#naming-and-the-shard-prefix)
  - [Security baseline and policy composition](#security-baseline-and-policy-composition)
  - [The security-baseline output surface](#the-security-baseline-output-surface)
  - [Module: access-logs-bucket](#module-access-logs-bucket)
  - [Module: bucket](#module-bucket)
  - [Module: events-bucket](#module-events-bucket)
  - [Remote-state key contract additions](#remote-state-key-contract-additions)
  - [CI mechanics](#ci-mechanics)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
  - [Phase 1: Internal core module](#phase-1-internal-core-module)
  - [Phase 2: access-logs-bucket producer](#phase-2-access-logs-bucket-producer)
  - [Phase 3: bucket reference consumer](#phase-3-bucket-reference-consumer)
  - [Phase 4: events-bucket](#phase-4-events-bucket)
  - [Phase 5: Fleet verification and doc closure](#phase-5-fleet-verification-and-doc-closure)
- [Open Questions](#open-questions)
  - [1. What retention default does the access-logs bucket ship?](#1-what-retention-default-does-the-access-logs-bucket-ship)
  - [2. How is the log-delivery policy grant conditioned?](#2-how-is-the-log-delivery-policy-grant-conditioned)
  - [3. Does the access-logs bucket default its own name?](#3-does-the-access-logs-bucket-default-its-own-name)
  - [4. Does the general-purpose bucket expose custom policy statements?](#4-does-the-general-purpose-bucket-expose-custom-policy-statements)
  - [5. What shape does the events-bucket destination surface take?](#5-what-shape-does-the-events-bucket-destination-surface-take)
  - [6. What happens if the LocalStack fidelity probes come back negative?](#6-what-happens-if-the-localstack-fidelity-probes-come-back-negative)
- [References](#references)
<!--toc:end-->

## Overview

Build the `modules/s3/` family per INV-0009's resolved layout: thin,
purpose-shaped bucket modules over one shared **internal core** at
`modules/s3/internal/core`, consumed by relative path so the core has no
independent version to drift. Initial scope is three consumable modules —
`s3/access-logs-bucket` (the per-region log sink and producer of a new
ADR-0020 contract), `s3/bucket` (the general-purpose secure bucket and
reference consumer), and `s3/events-bucket` (object-event notifications) —
each shipping the F2 security baseline, the F4 tri-state access-logging
contract, and full plan/apply test coverage from the first commit.

Per operator direction, phase tracking lives **in this document** (tasks +
success criteria per phase below) instead of per-module IMPL docs; this
supersedes INV-0009's per-module-IMPL recommendation.

## Goals and Non-Goals

### Goals

- One internal core module owning the security baseline: Block Public
  Access, BucketOwnerEnforced, HTTPS-only + TLS >= 1.2 deny policy, opt-in
  VPCE-only restriction, SSE-KMS default with CMK override, versioning off
  by default, MPU-abort lifecycle hygiene, composed global-unique naming
  with an opt-in shard prefix.
- Three consumable purpose modules (`access-logs-bucket`, `bucket`,
  `events-bucket`) that stay thin: type-specific surface only, everything
  else inherited from the core.
- The reserved remote-state key
  `<account_name>/<region>/s3/access-logs/terraform.tfstate` as the
  zero-configuration default log sink for every bucket stack, wired through
  the fleet's first **count-gated** `data.terraform_remote_state` read.
- ADR-0020 compliance from day one: key-template plan assertions (all three
  tri-state paths), README contract sections, ADR table rows.
- LocalStack **Community** apply coverage for the whole in-scope family (no
  Pro tier needed), including the two F6 fidelity probes.
- CI correctness for the nesting: a core edit must re-run every purpose
  module's plan suite (changed-modules fan-out rule).

### Non-Goals

- `s3/cloudfront-origin-bucket` and `s3/presigned-transfer-bucket` —
  deferred per INV-0009 OQ-8; they stay cataloged in INV-0009 F5 and get
  their own build-order call (and INV-0009 OQ-5 resolution) when picked up.
- Cross-region replication, object lock, website hosting, CloudTrail data
  events, MFA delete — none are in the F5 catalog; new needs mean new
  purpose modules, not new knobs on these.
- Creating SQS queues / SNS topics / EventBridge rules — the events-bucket
  points at destinations owned by other stacks (their resource policies
  included).
- Any live-repo (Terragrunt) changes — the reserved `s3/access-logs` stack
  path is documented here and in ADR-0020, enforced there.

## Background

INV-0009 resolved the family's shape on 2026-08-01/02 (all eight OQs):
internal core via relative path (OQ 1 = c, conditional on the core never
gaining a versioned source), flat reserved state key (OQ 2), tri-state
access-logging object with lookup default and sending-bucket-name prefix
(OQ 3), SSE-KMS aws/s3 default with CMK override (OQ 4), opt-in
VPCE-only via explicit endpoint list (OQ 6), composed naming plus opt-in
5-char random shard prefix (OQ 7), and the trimmed three-module build
order (OQ 8). See INV-0009 F1-F6 for the full findings; this design does
not re-litigate them.

Fleet context that shapes the implementation:

- **ADR-0020** governs every cross-module state read: composed key,
  plan-suite `config.key` assertion, README contract section. The s3 family
  adds the first *conditional* read (F4's count-gated data source), so the
  assertion pattern gains a disabled-path variant.
- **IMPL-0015** provides the six Terragrunt globals every remote-state
  consumer declares (`account_name`, `account_id`, `region`,
  `remote_state_bucket`, `remote_state_bucket_region`, `deploy_role_name`)
  and the cross-account `assume_role` read shape; the shared
  `test/fixtures/terragrunt-inputs.tfvars` supplies them at test time.
- **ADR-0019 / IMPL-0016 CI**: the static gate auto-discovers every
  directory containing `.tf` files under `modules/` (the internal core is
  picked up with no script change), while `scripts/changed-modules.sh`
  scopes the plan/apply matrix to changed leaf modules — which today has
  **no fan-out from an internal module to its consumers**. Phase 1 closes
  that gap.
- **Fleet conventions**: `required_version = ">= 1.1"` + AWS provider
  `~> 6.2` (the core also adds the `random` provider — a fleet first);
  preconditions for cross-variable checks (variable validations cannot
  reference other variables at the fleet floor); tflint attribute order
  (`nullable` last); terraform-docs USAGE.md inject; per-module README.
- **Test-visibility constraint** (drives the design of the baseline
  outputs): `terraform test` assertions can only address **root-module**
  resources and module **outputs** — a purpose module's plan suite cannot
  reach inside `module.core` to assert on its resources. The core is
  therefore tested directly (its own suite, where its resources ARE the
  root), and purpose modules pin the *composed result* through a
  re-exported baseline output object.

## Detailed Design

### Family layout and the nesting exemption

```text
modules/s3/
├── internal/
│   └── core/               # the shared security core — NOT independently consumable
├── access-logs-bucket/     # per-region log sink; ADR-0020 producer
├── bucket/                 # general-purpose secure bucket; reference consumer
└── events-bucket/          # bucket + notification surface
```

Purpose modules consume the core with `source = "../internal/core"` — a
relative path resolved inside the same cloned ref, so the live repo's
`//modules/s3/<purpose>?ref=<tag>` pin covers the core atomically.
**Standing condition (INV-0009 OQ 1):** the core must never gain a
versioned source (registry or git-ref). Phase 5 adds a grep guard for
this to the static gate. The `internal/` directory name is the signal
that the module is not a valid Terragrunt target; each purpose module's
README and the core's own README state it.

Terragrunt still sees exactly one consumable module per stack — the
nesting is invisible to the live repo, which is why the
no-module-in-module rule is bent here and nowhere else.

### The internal core interface

The core owns the bucket and every baseline companion resource. Its
variable surface (all consumed by the purpose modules, none directly by
operators):

| Variable | Type | Default | Notes |
|---|---|---|---|
| `name` | string | required | Logical name; validation: lowercase alphanumeric + hyphens, 3-37 chars (leaves room for the suffix) |
| `name_override` | string | null | Escape hatch: verbatim bucket name, skips composition (INV-0009 OQ 7) |
| `shard_prefix_enabled` | bool | false | Opt-in 5-char random prefix (below) |
| `account_id` | string | required | Name-composition input (Terragrunt global) |
| `region` | string | required | Name-composition input (Terragrunt global) |
| `encryption` | object({ mode = optional(string, "kms"), kms_key_arn = optional(string) }) | {} | `mode` in {kms, s3}; `kms` + null key = AWS-managed aws/s3 key; `s3` = AES256 (access-logs only); precondition: `kms_key_arn` requires `mode = "kms"` |
| `versioning_enabled` | bool | false | Operator decision (INV-0009 F2) |
| `force_destroy` | bool | false | |
| `abort_incomplete_multipart_days` | number | 7 | The hygiene lifecycle rule |
| `extra_lifecycle_rules` | list(object) | [] | Typed minimal shape (id, prefix, expiration_days, ...); used by access-logs retention |
| `allowed_vpc_endpoint_ids` | list(string) | [] | Non-empty adds the VPCE-only deny (INV-0009 OQ 6) |
| `internal_policy_statements` | list(object) | [] | Purpose-module statement injection: the module's own statements (access-logs delivery grant; future OAC) plus the pass-through target for the consumer-facing `additional_policy_statements` (OQ 4 — additive-only; reserved-sid validation) |
| `logging` | object({ target_bucket = string, prefix = optional(string) }) or null | null | Pre-resolved by the caller (the remote-state read lives in the purpose module — see Module: bucket); null prefix defaults to `<composed-name>/` inside the core |
| `tags` | map(string) | {} | |

Outputs: `bucket_id`, `bucket_name` (composed), `bucket_arn`,
`bucket_policy_json`, `logging_target` + `logging_prefix` (resolved;
null/empty when logging is off), and the `security_baseline` object
(next sections).

Core-owned preconditions (on the bucket resource, since cross-variable
validation is unavailable at the fleet floor):

1. Composed (or overridden) name is 3-63 chars and matches the S3 charset.
2. `encryption.kms_key_arn` set requires `encryption.mode == "kms"`.
3. `logging.target_bucket`, when set, differs from the module's own
   composed name (self-logging loop guard).

### Naming and the shard prefix

Default composed name: `<name>-<account_id>-<region>`. With
`shard_prefix_enabled = true`, a `count`-gated `random_string` (5 chars,
lowercase alphanumeric) prepends: `<shard>-<name>-<account_id>-<region>`.
The `random` provider joins the core's `required_providers` (`~> 3.7`).
The prefix is stable across applies (random_string only regenerates on
input changes); **toggling the flag after creation renames and therefore
replaces the bucket** — README documents the destructive toggle.
`name_override` bypasses composition entirely; the length/charset
precondition still applies to it.

### Security baseline and policy composition

Fixed (no variable), per INV-0009 F2:

- `aws_s3_bucket_public_access_block` — all four flags on.
- `aws_s3_bucket_ownership_controls` — `BucketOwnerEnforced`. This holds
  for the access-logs bucket too: modern log delivery writes via the
  `logging.s3.amazonaws.com` **policy grant**, which does not need ACLs,
  so the F2 table's sketched ownership exemption is unnecessary and the
  family ships one fixed ownership mode everywhere.
- Bucket policy statements: deny `aws:SecureTransport = false`; deny
  `s3:TlsVersion < 1.2`.

Default-on, overridable: SSE-KMS with aws/s3 + `bucket_key_enabled = true`
(CMK via `kms_key_arn`; access-logs pins SSE-S3 per F3), MPU-abort after
7 days. Default-off: versioning, VPCE-only deny (non-empty
`allowed_vpc_endpoint_ids` adds a deny-unless-`aws:SourceVpce`-in-list
statement; README carries the locks-out-console-and-deployer caveat).

The policy document is composed in the core from: the two fixed denies +
the optional VPCE deny + `internal_policy_statements` (purpose-module
injections, which include any operator-supplied
`additional_policy_statements` passed through by the consumer modules —
OQ 4). One `aws_s3_bucket_policy` resource; statements carry stable
`sid`s so plan suites can assert on them by name via `jsondecode`. The
merge is **additive-only**: baseline statements always render regardless
of what is injected, and a core validation rejects injected statements
carrying a reserved baseline sid, so nothing an operator adds can shadow
or replace the baseline.

### The security-baseline output surface

Because purpose-module tests cannot address `module.core`'s resources
(Background, test-visibility constraint), the core emits one structured
output **derived from actual resource attributes** (not echoed inputs):

```hcl
output "security_baseline" {
  value = {
    block_public_acls        = aws_s3_bucket_public_access_block.this.block_public_acls
    block_public_policy      = aws_s3_bucket_public_access_block.this.block_public_policy
    ignore_public_acls       = aws_s3_bucket_public_access_block.this.ignore_public_acls
    restrict_public_buckets  = aws_s3_bucket_public_access_block.this.restrict_public_buckets
    object_ownership         = one(aws_s3_bucket_ownership_controls.this.rule).object_ownership
    sse_algorithm            = ...   # from the encryption configuration resource
    kms_key_arn              = ...   # null on the aws/s3 default and on SSE-S3
    bucket_key_enabled       = ...
    versioning_status        = ...
    mpu_abort_days           = ...
    tls_deny_sids_present    = ...   # both fixed sids found in the composed policy
    vpce_restricted          = ...
  }
}
```

Every purpose module re-exports it verbatim
(`output "security_baseline" { value = module.core.security_baseline }`),
and one **identical** `security_baseline.tftest.hcl` per purpose module
pins it (IMPL-0017's ported-identical-surface precedent) — so a core
change that silently alters a sibling's composed baseline fails that
sibling's plan suite in CI.

### Module: access-logs-bucket

The per-region singleton log sink; ADR-0020 producer. Deliberate
asymmetries (INV-0009 F3):

- **SSE-S3 pinned** (`encryption = { mode = "s3" }` into the core; no CMK
  override exposed — log delivery does not write to KMS targets).
- **No access_logging surface** (it logs nowhere; self-logging loop).
- **Versioning pinned off** (not even the variable).
- Injects the log-delivery grant via `internal_policy_statements`:
  principal `logging.s3.amazonaws.com`, `s3:PutObject` on `<arn>/*`,
  conditioned per OQ 2 below.
- Default retention lifecycle via `extra_lifecycle_rules`, per OQ 1 below.
- Name default per OQ 3 below.

Operator surface stays tiny: name bits, tags, retention knob, the two
Terragrunt name-composition globals. Contract outputs: `bucket_name`
(the consumer set), plus `bucket_arn` + `bucket_id` (additive).

A **non-default sink** is this same module deployed at another
`s3/<stack-name>` with overridden vars; consumers point at it via the
tri-state `target_bucket` override (INV-0009 OQ 2).

### Module: bucket

The general-purpose secure bucket and reference consumer — its
type-specific surface is exactly the F4 tri-state plus the six Terragrunt
globals:

```hcl
variable "access_logging" {
  type = object({
    enabled       = optional(bool, true)
    target_bucket = optional(string) # null = remote-state lookup
    prefix        = optional(string) # null = "<composed-name>/"
  })
  default = {}
}

data "terraform_remote_state" "access_logs" {
  count   = var.access_logging.enabled && var.access_logging.target_bucket == null ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.account_name}/${var.region}/s3/access-logs/terraform.tfstate"
    region = var.remote_state_bucket_region
    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}
```

The read stays in the purpose module (not the core) for three reasons:
the fleet's read-at-use-site convention, the six globals stay out of the
core's interface, and — decisive — ADR-0020's `config.key` plan assertion
can only address a root-module data source. The resolved
`{ target_bucket, prefix }` (from state, override, or null) passes into
the core's `logging` input; the core resolves the null prefix to
`<composed-name>/` because only it knows the final composed name (the
shard prefix is unknown until apply).

Everything else is pass-through to the core: `versioning_enabled`,
`kms_key_arn`, `force_destroy`, `allowed_vpc_endpoint_ids`,
`shard_prefix_enabled`, `name_override`, MPU days, tags — plus
`additional_policy_statements` (OQ 4: appended additively into the
core-composed policy; the baseline denies always render and reserved
baseline sids are rejected).

**Bootstrapping order:** in a fresh account+region, the reserved
`s3/access-logs` stack applies first; until then any bucket stack on the
default tri-state fails its plan with the documented loud-but-vague
`Unable to find remote state` (README contract section names the expected
key, per ADR-0020 practice). A deliberately log-less stack sets
`access_logging = { enabled = false }`.

### Module: events-bucket

`bucket`'s surface (tri-state and `additional_policy_statements`
included) plus the notification type surface. `aws_s3_bucket_notification` is a **per-bucket singleton** — all
destinations live in one resource in the purpose module's root (so plan
suites can assert on it directly). Destination variables per OQ 5 below;
a precondition requires at least one destination (an events bucket with
no destinations is a misconfiguration). Destination resource policies
(SQS queue policy / SNS topic policy allowing `s3.amazonaws.com` from the
bucket ARN) are owned by the destination stacks; the README says so and
the apply-suite fixture demonstrates the queue-policy shape.

### Remote-state key contract additions

ADR-0020's tables gain (Phase 2/3):

| Consumer module | Read | Key template | Producer |
|---|---|---|---|
| s3/bucket | access-logs (conditional) | `<acct>/<region>/s3/access-logs/terraform.tfstate` | s3/access-logs-bucket |
| s3/events-bucket | access-logs (conditional) | same | same |

Producer-side: general bucket stacks land at
`<account_name>/<region>/s3/<stack-name>/terraform.tfstate`;
`access-logs` is the one **reserved** stack name. The reads carry the
IMPL-0015 `assume_role` block like the other 12. ADR-0020 also gains a
note that the fleet now contains conditional reads, whose plan suites
must assert the composed key on the enabled path **and** the absence of
the data source on the disabled/override paths.

### CI mechanics

- **Static gate:** no change needed — `list_modules` discovers any
  directory with `.tf` files, so `s3/internal/core` gets fmt / validate /
  tflint / terraform-docs like every module (it ships its own
  `.tflint.hcl` + USAGE.md).
- **changed-modules.sh:** new fan-out rule — a diff under
  `modules/<service>/internal/**` adds **every leaf module under
  `modules/<service>/`** to the changed set (the internal module itself
  included, for its own plan suite). Covered by new
  `changed-modules.test.sh` cases via the existing
  `CHANGED_FILES_OVERRIDE` seam.
- **justfile:** `just tf <action> s3/internal/core` and the three purpose
  paths work unchanged (the recipes take any path under `modules/`);
  verified as a Phase 1 task, no recipe edit expected.
- **Tiers:** all three purpose modules ship `tests-localstack/`
  (Community, like `network/vpc-lookup`); the family adds **no** Pro
  tier. The core ships `tests/` only (plan; it is not independently
  applyable against a backend by design).

## Testing Strategy

Four layers, cheapest first:

1. **Core plan suite** (`modules/s3/internal/core/tests/`, mock provider):
   the core is the root module here, so its resources are directly
   assertable — the deep pin. Covers: all fixed baseline resources, policy
   sid composition (jsondecode), encryption modes (kms default / CMK /
   s3), naming + shard-prefix + name_override, logging tri-state wiring
   and prefix defaulting, every validation and precondition via
   `expect_failures` runs.
2. **Purpose-module plan suites** (the CI gate):
   - one **identical** `security_baseline.tftest.hcl` across all three
     modules pinning the re-exported `security_baseline` output;
   - `default.tftest.hcl` per module: type surface + the ADR-0020
     assertions — enabled path pins
     `data.terraform_remote_state.access_logs[0].config.key`
     (`override_data` stub, config remains assertable), disabled and
     override paths assert the data source composes zero instances;
   - `validation.tftest.hcl`: tri-state combinations, naming bounds,
     events-bucket destination precondition, and the OQ-4 guarantees —
     an additive statement renders alongside the untouched baseline sids,
     and a reserved-sid statement fails via `expect_failures`.
3. **Community apply suites** (`tests-localstack/`, token-free Community
   image, `SERVICES=s3,sts` + `sqs,sns,events` for events-bucket):
   - access-logs-bucket: standalone real apply.
   - bucket: composing fixture instantiates the **real**
     access-logs-bucket module and seeds the reserved-key state object
     into the shared `remote_state_bucket` (the proxy / read-replica
     fixture precedent), then applies with the default lookup. Runs **F6
     probe 1** (does log delivery materialize objects?).
   - events-bucket: fixture SQS queue + queue policy (+ EventBridge);
     runs **F6 probe 2** (do notifications fire fast enough to assert?).
   - Probe outcomes land in each FINDINGS.md (IMPL-0017 parity-note
     precedent); a negative probe falls back to config-surface depth
     (OQ 6a).
4. **Static gate:** fmt / validate / tflint / terraform-docs across the
   four new directories, automatically.

## Phases

### Phase 1: Internal core module

Tasks:

- [ ] Scaffold `modules/s3/internal/core` (versions.tf with aws `~> 6.2`
      + random `~> 3.7`, `required_version = ">= 1.1"`; `.tflint.hcl`;
      terraform-docs USAGE.md; README stating not-independently-consumable)
- [ ] Naming: `name` validation, `name_override`, shard-prefix
      `random_string`, composed-name local, length/charset precondition
- [ ] Baseline resources: bucket, public-access block, ownership
      controls, encryption configuration (mode object + preconditions),
      versioning, lifecycle (MPU-abort + `extra_lifecycle_rules`)
- [ ] Policy composition: fixed TLS denies + VPCE opt-in +
      `internal_policy_statements`, stable sids, one policy resource
- [ ] Logging pass-through (`logging` object, prefix defaulting,
      self-logging precondition)
- [ ] Outputs: bucket identifiers, `bucket_policy_json`, logging
      resolution, `security_baseline` (attribute-derived)
- [ ] Core plan suite per Testing Strategy layer 1
- [ ] changed-modules.sh internal fan-out rule + self-test cases
- [ ] CLAUDE.md: start the `modules/s3/` section; commit conventionally

Success criteria:

- `just tf validate|fmt|lint|test s3/internal/core` all green
- `scripts/changed-modules.test.sh` green including the new fan-out cases
  (a seeded core-file change lists all `s3/` leaf modules)
- `just static` green repo-wide (core auto-discovered, USAGE.md fresh)

### Phase 2: access-logs-bucket producer

Tasks:

- [ ] Module over the core: SSE-S3 pinned, versioning pinned off, no
      access_logging surface, log-delivery grant statement (OQ 2a:
      `aws:SourceAccount`-only), retention lifecycle default (OQ 1a:
      90-day expiration, `log_retention_days`, null disables), name
      default (OQ 3a: `"access-logs"`)
- [ ] Contract outputs: `bucket_name` + additive `bucket_arn`, `bucket_id`
- [ ] Plan suites: shared `security_baseline.tftest.hcl` (first
      instance), default shape (grant sid + AES256 + retention),
      validations
- [ ] Community apply suite + FINDINGS.md
- [ ] README with the ADR-0020 producer contract section (reserved key,
      non-default-sink pattern); USAGE.md
- [ ] ADR-0020: add the s3 producer row + reserved-stack-name note
- [ ] CLAUDE.md update; root README module table regen; commit

Success criteria:

- Plan + Community apply suites green (`just tf test s3/access-logs-bucket`,
  `just tf test-localstack s3/access-logs-bucket`)
- ADR-0020 carries the s3 shape; `just static` green

### Phase 3: bucket reference consumer

Tasks:

- [ ] Module over the core: six Terragrunt globals, tri-state
      `access_logging`, count-gated remote-state read with `assume_role`,
      resolved logging into the core; pass-through baseline knobs
- [ ] `additional_policy_statements` pass-through (OQ 4b: additive-only
      merge into `internal_policy_statements`, reserved-baseline-sid
      validation in the core)
- [ ] Plan suites: shared baseline file; ADR-0020 `config.key` assertion
      (enabled path) + zero-instance assertions (disabled + override
      paths); tri-state and naming validations; OQ-4 assertions (additive
      statement renders beside intact baseline sids; reserved sid fails)
- [ ] Community apply: composing fixture (real access-logs-bucket module
      + reserved-key state seed), default-lookup apply, **F6 probe 1**,
      FINDINGS.md
- [ ] README consumer contract section; USAGE.md
- [ ] ADR-0020: consumer row + the conditional-read note
- [ ] CLAUDE.md update; root README regen; commit

Success criteria:

- All three tri-state paths pinned green in the plan suite
- Community apply green with the default lookup end-to-end (state seeded
  at the reserved key, read back through assume_role)
- Probe-1 outcome recorded in FINDINGS.md either way

### Phase 4: events-bucket

Tasks:

- [ ] Module over the core: bucket surface + notification singleton +
      destination variables (OQ 5a: typed `sns_topics` / `sqs_queues`
      lists + `eventbridge_enabled` bool) + at-least-one-destination
      precondition
- [ ] Plan suites: shared baseline file; notification shape; ADR-0020
      assertions (same three paths); destination precondition
      `expect_failures`
- [ ] Community apply: SQS + queue-policy fixture (+ EventBridge), **F6
      probe 2**, FINDINGS.md
- [ ] README (contract section + destination-policy ownership note);
      USAGE.md; CLAUDE.md; root README regen; commit

Success criteria:

- Plan + Community apply suites green
- Probe-2 outcome recorded in FINDINGS.md either way

### Phase 5: Fleet verification and doc closure

Tasks:

- [ ] Static-gate guard: grep asserting the core is consumed only via the
      relative path (no versioned source anywhere in `modules/s3/`)
- [ ] Full verification pass: `just static`; all four plan suites; all
      three Community applies
- [ ] Fidelity greps: reserved-key literal consistent across module,
      tests, ADR-0020, READMEs; no un-prefixed fixture keys
- [ ] docz closure: INV-0009 → Concluded (probe results recorded);
      DESIGN-0019 → Implemented; `docz update` (restore any TOC
      mangling); root README regen; commit

Success criteria:

- Everything green in one run from a clean tree
- The OQ-1 condition is machine-enforced (versioned-core-source grep
  fails the static gate)
- INV-0009 and this design carry final statuses; CI fully green on the PR

## Open Questions

Numbering continues INV-0009's convention: option (a) is the
recommendation; pick a letter or write in an alternative.

> **Resolved 2026-08-02 (operator review):** 1 = **a**, 2 = **a**,
> 3 = **a**, 4 = **b modified** (additive-only — the core baseline stays
> fixed; operator statements add, never remove), 5 = **a**, 6 = **a**.
> The OQ-4 resolution is folded back into the Detailed Design (policy
> composition, bucket surface, Testing Strategy, Phase 3 tasks).

### 1. What retention default does the access-logs bucket ship?

**Resolved (a).**

- a) **(Chosen)** Expiration after 90 days, configurable
  (`log_retention_days`, null disables) — INV-0009 F3's sketch; logs are
  operational exhaust, not records; unbounded growth is the real
  foot-gun.
- b) No default expiration — retain until the operator opts in; safest
  for compliance-minded accounts, but the bucket grows unbounded by
  default.
- c) 90-day expiration + transition to STANDARD_IA at 30 days — cheaper
  at volume, but IA's 128KiB minimum-billable-object-size penalizes tiny
  log objects, which access logs mostly are.

### 2. How is the log-delivery policy grant conditioned?

**Resolved (a).**

- a) **(Chosen)** `aws:SourceAccount` only — any bucket in the
  account can point at the sink with zero per-source policy edits, which
  is exactly the zero-configuration default the tri-state promises.
  Cross-account delivery stays impossible.
- b) `aws:SourceAccount` plus an `aws:SourceArn` source-bucket allow-list
  input — tighter, but reintroduces the per-source coordination the
  reserved path exists to remove, and the list is unknowable at
  sink-creation time (chicken-and-egg).

### 3. Does the access-logs bucket default its own name?

**Resolved (a).**

- a) **(Chosen)** `name` defaults to `"access-logs"` — the singleton
  becomes literally zero-configuration
  (bucket `access-logs-<account_id>-<region>`), matching the reserved
  stack path; overridable for non-default sinks.
- b) `name` required like every other module — uniform surface, one more
  line in every live stack.

### 4. Does the general-purpose bucket expose custom policy statements?

**Resolved (b, modified — additive-only).** The consumer modules
(`bucket`, `events-bucket`) expose `additional_policy_statements`, but
the merge is strictly **additive**: the core's fixed baseline denies and
the purpose module's internal statements always render, operator
statements can only add alongside them, and a validation rejects the
reserved baseline sids so an additive statement can never shadow or
replace one. The core default remains authoritative — this is an
escape hatch for extra grants (cross-account reads, service principals),
not a way to loosen the baseline.

- a) No — `internal_policy_statements` stays
  core-internal (purpose modules only). A raw statement passthrough on
  `s3/bucket` re-opens the wide-wrapper door and un-audits the policy
  surface; a recurring statement need is a new purpose module (the
  family's founding premise).
- b) **(Chosen, additive-only)** Expose `additional_policy_statements`
  on `s3/bucket` as a documented
  escape hatch — pragmatic for one-off cross-account read grants without
  a module release; the additive-only merge + reserved-sid validation
  keeps the "not a foot-gun" guarantee intact.

### 5. What shape does the events-bucket destination surface take?

**Resolved (a).**

- a) **(Chosen)** Three typed inputs mirroring the provider's
  blocks: `sns_topics` + `sqs_queues` as
  `list(object({ arn, events, filter_prefix, filter_suffix }))` and
  `eventbridge_enabled` bool (EventBridge is all-events by design — no
  filters exist on it).
- b) One `notifications` object wrapping all three — a single variable,
  but nullable-inner-object ergonomics for no expressive gain.
- c) Raw passthrough of the provider's notification schema — maximum
  flexibility, no opinion, invites the config sprawl the module exists
  to prevent.

### 6. What happens if the LocalStack fidelity probes come back negative?

**Resolved (a).**

- a) **(Chosen)** Ship anyway at config-surface depth: apply suites
  assert the logging/notification **configuration** round-trips, skip
  delivery/firing assertions, and FINDINGS.md records the parity gap
  (exactly IMPL-0017's LocalStack-rotation precedent). Delivery is AWS's
  contract, not the module's.
- b) Treat a negative probe as blocking — hold the apply tier until a
  real-AWS (or Pro) check exists; more certainty, but it gates the family
  on infrastructure outside this repo for behavior Terraform does not
  manage.

## References

- INV-0009 — S3 module family layout and security baseline (all findings
  + resolved OQs this design implements)
- ADR-0020 — remote-state key contract (gains the s3 rows + the
  conditional-read note)
- ADR-0001 / IMPL-0015 — remote-state composition + the six Terragrunt
  globals and assume_role read shape
- ADR-0019 / IMPL-0016 — static gate + changed-modules matrix (the
  fan-out rule lands in `scripts/changed-modules.sh`)
- IMPL-0017 — ported-identical-surface + parity-note precedents (the
  shared `security_baseline.tftest.hcl` and probe-fallback patterns)
- `network/vpc-lookup` — the Community apply-tier template
- `rds/proxy`, `rds/read-replica` — the composing-fixture precedent
  (Phase 3's apply fixture)
- AWS docs: S3 server access logging (same-region, SSE-S3-only target,
  `logging.s3.amazonaws.com` grant); Block Public Access; Object
  Ownership; bucket naming rules; S3 event notifications
