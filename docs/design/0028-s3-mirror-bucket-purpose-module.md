---
id: DESIGN-0028
title: "S3 mirror bucket purpose module"
status: Draft
author: Donald Gifford
created: 2026-09-15
---

<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0028: S3 mirror bucket purpose module

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-09-15

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Change map](#change-map)
  - [Why a new purpose module, not an evidence-bucket fork](#why-a-new-purpose-module-not-an-evidence-bucket-fork)
  - [Pinned posture](#pinned-posture)
  - [The four policy statements](#the-four-policy-statements)
  - [Naming and globals footprint](#naming-and-globals-footprint)
  - [Logging posture: explicit target, no remote-state read](#logging-posture-explicit-target-no-remote-state-read)
  - [Lifecycle: noncurrent-to-IA only](#lifecycle-noncurrent-to-ia-only)
  - [Object lock surface](#object-lock-surface)
  - [Outputs](#outputs)
  - [Reserved-sid treatment](#reserved-sid-treatment)
  - [Remote-state posture](#remote-state-posture)
  - [CI mechanics](#ci-mechanics)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
  - [Phase 1: Module scaffold + policy composition](#phase-1-module-scaffold--policy-composition)
  - [Phase 2: Plan suite (the gate)](#phase-2-plan-suite-the-gate)
  - [Phase 3: Apply + sandbox proof](#phase-3-apply--sandbox-proof)
- [Open Questions](#open-questions)
  - [1. Does `vpc_endpoint_ids` drive both the allow and the core DenyOutsideVpce?](#1-does-vpc_endpoint_ids-drive-both-the-allow-and-the-core-denyoutsidevpce)
  - [2. How are the three mirror statement sids protected from operator shadowing?](#2-how-are-the-three-mirror-statement-sids-protected-from-operator-shadowing)
  - [3. What is the naming interface: family standard or a single `bucket_name`?](#3-what-is-the-naming-interface-family-standard-or-a-single-bucket_name)
  - [4. Which Terragrunt globals does the module declare?](#4-which-terragrunt-globals-does-the-module-declare)
  - [5. What is the Object Lock variable shape?](#5-what-is-the-object-lock-variable-shape)
  - [6. Does DenyPolicyMutation get an off-switch?](#6-does-denypolicymutation-get-an-off-switch)
  - [7. How is the cross-account publisher allow expressed?](#7-how-is-the-cross-account-publisher-allow-expressed)
  - [8. What harness runs the opt-in sandbox policy-evaluation proof?](#8-what-harness-runs-the-opt-in-sandbox-policy-evaluation-proof)
- [References](#references)
<!--toc:end-->

## Overview

New S3 purpose module `modules/s3/mirror-bucket` serving the sluice
provider network mirror (workstream 2 of the sluice roadmap): a thin
wrapper over `modules/s3/internal/core` that ships the serving bucket
with VPC-only anonymous reads, deny-delete by default, and an
admin-pinned policy-mutation guard — so the mirror's security posture
is reviewed once, here, rather than re-derived per environment.

## Goals and Non-Goals

### Goals

- A serving-ready mirror bucket with the full control set from sluice
  DESIGN-0002, adapted to this fleet's S3 family architecture
  (DESIGN-0019 / DESIGN-0022).
- Anonymous `s3:GetObject` reachable only through declared VPC
  endpoints; unreachable otherwise — with all four Block Public
  Access settings staying `true` (a `aws:SourceVpce`-conditioned
  policy evaluates as non-public).
- Deny-delete by default, with a break-glass exception that is
  count-gated (unconditional deny on an empty list — an empty
  `NotIn`/`StringNotEquals` values list is invalid IAM).
- Policy-mutation deny default-on, scoped to declared admin
  principals.
- SSE-S3 pinned (anonymous readers cannot decrypt SSE-KMS objects —
  by decision, not oversight), versioning pinned on.
- `mirror_url` output rendering the REST endpoint with trailing
  slash, ready to paste into `provider_installation`.
- Family-pattern testing: plan suites asserting rendered policy JSON
  statement-by-statement, a Community LocalStack apply, and a
  tagged opt-in sandbox run proving policy evaluation.

### Non-Goals

- **No IAM resources.** The GitHub OIDC publisher role from sluice
  DESIGN-0002 (`create_publisher_role`, `publisher_repo_subjects`,
  `publisher_role_arn`) is provisioned out of band — this is an
  explicit divergence from the sluice design, recorded below.
  Same-account publishing needs no bucket-policy grant at all.
- **Managing mirror *content*.** Object layout is the mirror CLI's
  job (sluice workstream 1).
- **CloudFront or any off-VPC serving path.**
- **Cross-region replication.** Same v1 ruling as sluice DESIGN-0002:
  re-apply from the manifest is the DR path.
- **Object Lock knobs beyond the issue's enable + days surface**
  (see OQ 5); legal holds; enabling lock on existing buckets
  (brownfield = new bucket + copy, the DESIGN-0022 ruling).
- **The remaining deferred purpose modules**
  (`cloudfront-origin-bucket`, `presigned-transfer-bucket`).

## Background

Sluice DESIGN-0002 specifies the mirror bucket (four policy
statements, optional Object Lock, optional publisher role, IA
lifecycle, access logging) and the program roadmap assigns its
Terraform module to this repo's shared-modules family. The issue
(gh-121) narrows that spec for this fleet:

- Thin wrapper over `modules/s3/internal/core` — the DESIGN-0019
  "new needs = new purpose modules" ruling.
- Do **not** fork `evidence-bucket`: it pins Object Lock on with
  mandatory retention plus the Terragrunt-globals + tri-state shape
  that does not fit here (explicit logging target instead).
- Publisher role out of scope (above).

Family prior art: DESIGN-0019 / IMPL-0018 (core architecture,
`internal_policy_statements` additive injection, the reserved-sid
pattern, the wrapper-module `required_providers` gotcha, the
`terraform test` variables-block and variables-validation
gotchas), DESIGN-0022 / IMPL-0021 (Object Lock core capability,
retention/expiration interplay, the variant-suite precedent,
`log_retention_days` → fixed-id core rule mapping in
`access-logs-bucket`), IMPL-0015 (six globals, uniform injection,
`assume_role` reads), IMPL-0020 (coherence validations, silent
widening lesson).

Two AWS behaviors the design leans on (from sluice DESIGN-0002,
unchanged): (1) a bucket policy conditioned on `aws:SourceVpce`
evaluates as non-public, so BPA stays all-true; (2) anonymous reads
cannot decrypt SSE-KMS objects, so SSE-S3 is a serving requirement.

## Detailed Design

### Change map

```text
modules/s3/internal/core/      NONE     (was: reserved-sid extension —
                                         struck at build, see OQ 2's
                                         build note; the core is untouched)
modules/s3/mirror-bucket/      CREATE   the purpose module
modules/s3/{bucket,events-bucket,
  evidence-bucket,
  access-logs-bucket}/         NONE     untouched
```

No core resource or type change is expected: every mirror behavior
composes from existing core inputs (`encryption`, pinned
`versioning_enabled`, `object_lock`, `extra_lifecycle_rules`,
`allowed_vpc_endpoint_ids`, `internal_policy_statements`,
`logging`). The single anticipated core edit is the reserved-sid
extension (OQ 2). If the OQ resolutions keep that shape, this DESIGN
rides one PR series with no family fan-out beyond the new leaf
(the fan-out triggers on `internal/**` diffs — the one-line guard
edit pays it once).

### Why a new purpose module, not an evidence-bucket fork

Three incompatibilities, each independently disqualifying:

1. `evidence-bucket` pins `object_lock.enabled = true` with a
   **required** retention duration; the mirror wants lock **off** by
   default with an opt-in days surface.
2. `evidence-bucket` pins SSE-KMS; the mirror requires SSE-S3
   (anonymous-read serving requirement).
3. `evidence-bucket` carries the `access_logging` tri-state +
   six-globals remote-state read; the mirror takes an explicit
   logging target with no fleet lookup.

A fork would start by unpinning everything the fork source pins —
that is a new purpose module wearing a costume. `bucket` is the
structural template (reference-consumer surface), not the parent.

### Pinned posture

Pinned in `main.tf` with **no variable** (the evidence-bucket
precedent — posture that must not drift is not exposed):

- `versioning_enabled = true` (mirror content is immutable release
  artifacts; noncurrent versions are the forensics record).
- `encryption = { mode = "s3" }` (SSE-S3/AES256 — the serving
  requirement above; a `kms_key_arn` on this module fails at plan
  via the core's existing precondition).
- F2 baseline verbatim: PAB all-true, BucketOwnerEnforced, TLS
  denies (`DenyInsecureTransport` + `DenyOldTls` render free from
  the core), MPU-abort hygiene.

### The four policy statements

All four compose in root `locals` and inject through the existing
`internal_policy_statements` → `additional_policy_statements`
additive channel (no core policy.tf change):

1. **`AllowMirrorReadFromVPCE`** — `Effect Allow`,
   `Principal "*"`, `Action s3:GetObject`,
   `Resource ["/*"]` (objects only — never the bucket ARN itself),
   `Condition StringEquals aws:SourceVpce = var.vpc_endpoint_ids`.
   Objects-only scope is deliberate: `ListBucket` on the bucket
   ARN is not granted (the mirror protocol needs static GETs, not
   listing; listing stays denied-by-default).
   - **Build-time probe P0:** no family suite has ever sent
     `principals = { "*" = ["*"] }` through the injection channel
     (existing uses are `AWS` and `Service`). The IMPL proves
     `aws_iam_policy_document` renders `Principal: "*"` from that
     shape at plan; fallback if it does not is a minimal core
     extension (explicit star-principal support in the injected
     statement schema), recorded as an IMPL task — not an OQ,
     because both shapes land in the same statement either way.
2. **`DenyOutsideVpce`** — not injected: reuse the core's opt-in
   by wiring `allowed_vpc_endpoint_ids = var.vpc_endpoint_ids`
   (OQ 1a). Deny `s3:*` unless `aws:SourceVpce` is in the list,
   alongside the allow — the allow opens the read path, the deny
   closes everything else (including reads that somehow miss the
   allow's condition shape).
3. **`DenyObjectDeletion`** — deny `s3:DeleteObject` +
   `s3:DeleteObjectVersion` on `["/*"]` to `Principal "*"` —
   **count-gated on `var.break_glass_principal_arns`**: empty list
   renders the statement with **no condition block** (absolute
   deny, the sluice default); non-empty renders it with
   `Condition StringNotEquals aws:PrincipalArn = <list>`
   (break-glass principals exempt). The gate exists because an
   empty condition-values list is invalid IAM — the same
   count-gated-read discipline as the family's remote-state reads.
4. **`DenyPolicyMutation`** — deny `s3:PutBucketPolicy` +
   `s3:DeleteBucketPolicy` on `[""]` (the bucket ARN, not objects)
   to `Principal "*"`, with
   `Condition StringNotEquals aws:PrincipalArn = var.policy_admin_principal_arns`,
   default-on per OQ 6. `policy_admin_principal_arns` is
   **required non-empty** (fail-closed at the variable: an empty
   admin list strands the stack — nobody could ever amend the
   policy — so it is rejected at plan, mirroring the fleet's
   no-auth-path precondition doctrine). Whether a disable toggle
   exists is OQ 6.

Validation on the new list variables follows the fleet's trust-input
doctrine (IMPL-0022: separate validation blocks per rule so each
rejection run is verifiable against the rule it names):
non-empty `vpc_endpoint_ids` with a `vpce-` id-format check,
exact-ARN regex on principal lists, wildcard rejection, duplicate
rejection. `break_glass_principal_arns` defaults `[]` (absolute
deny — content mistakes fix forward with new versions; a true
purge is a reviewed PR that adds a principal, applies, deletes,
reverts, per sluice DESIGN-0002).

### Naming and globals footprint

See OQ 3 (naming) and OQ 4 (globals). The core always needs
`account_id` + `region` for name composition; the mirror needs no
other global (no remote-state read — OQ 4a declares only those
two). The sluice `bucket_name` arrives via the family's
`name_override` hatch (externally-dictated names are exactly its
use case).

### Logging posture: explicit target, no remote-state read

The module takes `access_log_bucket` (string, `null` disables) +
`access_log_prefix` (`null` → the core's `<composed-name>/`
default) and passes the resolved object straight to the core's
`logging` input — **no `data.terraform_remote_state` block, no
tri-state, none of the remote-state globals**. The sink is the
existing `access-logs-bucket` stack, referenced by name. Rationale
(sluice DESIGN-0002 + the issue): read-path forensics for a
public-shape serving bucket belong to an explicitly chosen sink,
not to whatever the fleet default lookup returns; and without the
lookup there is no bootstrapping order between the mirror stack
and the sink stack beyond the operator applying the sink first.
The core's self-logging precondition still guards
`target_bucket == <own name>`.

### Lifecycle: noncurrent-to-IA only

One fixed-id core rule mapped from `var.noncurrent_version_ia_days`
(`null` disables — no rule rendered), following the
`access-logs-bucket` `log_retention_days` precedent:

- `noncurrent_version_transitions = [{ noncurrent_days = var.noncurrent_version_ia_days, storage_class = "STANDARD_IA" }]`.
- **Never expiration** (current or noncurrent): mirror artifacts
  are immutable releases; expiry destroys the forensics record
  and breaks pinned installs. There is no expiration variable at
  all — the absence is the guarantee (stronger than a
  default-null: no input shape can express "expire the mirror").
- Transitions are lock-compatible (DESIGN-0022 interplay section),
  so the IA rule composes with opt-in Object Lock rather than
  conflicting with it.

### Object lock surface

Per OQ 5 (issue shape): `enable_object_lock` (bool, default
`false`) + `object_lock_retention_days`, mapped onto the core's
`object_lock = { enabled, mode = "COMPLIANCE", days }`. The core's
existing guards do the heavy lifting unchanged: versioning
coupling (satisfied — versioning is pinned on),
days-xor-years (satisfied — years is never set), and the
retention-set-but-disabled coherence validation. COMPLIANCE mode
is pinned, not selected: the mirror's threat is quiet content
mutation, and GOVERNANCE's bypass exists for lower-stakes tiers.

### Outputs

- `bucket_id`, `bucket_arn` — core re-exports (family standard).
- `mirror_url` — `"https://<bucket-name>.s3.<region>.amazonaws.com/"`,
  composed from the core's `bucket_name` output + `var.region`,
  **trailing slash pinned by a plan assertion** (the Double-slash /
  missing-slash failure modes both break `provider_installation`
  parsing silently — the value is asserted, not eyeballed).
  Partition note: `arn:aws` / `s3.<region>.amazonaws.com` assume
  the standard partition, consistent with the fleet's existing
  aws-partition-only compositions (naming.tf).
- Plus the family's test windows, re-exported verbatim:
  `security_baseline`, `bucket_policy_json`, `lifecycle_rule_ids`,
  `logging_target` / `logging_prefix`.
- Deliberately absent: `publisher_role_arn` (no IAM resources —
  the sluice output has no producer here).

### Reserved-sid treatment

See OQ 2 (and its build note — the guard lives at the mirror
root, not in the core). The mirror injects three non-baseline
sids through a channel whose core guard covers only the three
baseline sids — so without treatment an operator
`additional_policy_statements` entry could shadow a mirror
statement by sid collision. The mirror root's
`additional_policy_statements` validation rejects all seven
reserved sids (three baseline + four mirror-composed, publisher
sid included), and the root `locals` merge (mirror statements
first, operator statements after) is collision-free by
construction.

### Remote-state posture

The mirror bucket is a normal named stack — no reserved flat key
(that is unique to the access-logs sink singleton). The
`access_log_bucket` input takes the sink's **bucket name** (not
its state key): no remote-state read, no ADR-0020 row, no
consumer-side key assertion. If a future consumer needs the
mirror's name/ARN it reads the standard
`<account_name>/<region>/s3/<name>/terraform.tfstate` shape.

### CI mechanics

- New leaf enters the plan matrix + Community tier automatically
  (test-directory discovery); the IMPL verifies with
  `just changed`.
- No `internal/**` diff exists (OQ 2 build note), so no family
  fan-out — the new leaf enters the plan matrix + Community tier
  automatically (test-directory discovery); the IMPL verifies with
  `just changed`.
- Wrapper-module gotcha honored: root `required_providers` must
  declare aws even though root holds no direct aws resource
  (tflint-ignored) — the `access-logs-bucket` Phase 2 lesson.
- Conftest credential gate: no credential surface (no secrets,
  no passwords) — nothing to gate, but the sweep covers the new
  files automatically.

## API / Interface Changes

New module `modules/s3/mirror-bucket` (issue interface, OQ
resolutions pending):

```hcl
variable "vpc_endpoint_ids"            # list(string), required, non-empty
variable "enable_object_lock"         # bool, default false
variable "object_lock_retention_days" # number, null default (OQ 5)
variable "break_glass_principal_arns" # list(string), default []
variable "policy_admin_principal_arns" # list(string), required non-empty
variable "noncurrent_version_ia_days" # number, null disables
variable "access_log_bucket"          # string, null disables
variable "access_log_prefix"          # string, null default
variable "tags"                       # map(string), default {}
# + naming (OQ 3) + two globals (OQ 4) + additional_policy_statements
#   (family-standard additive pass-through) + OQ 6/7 resolutions
```

```hcl
output "bucket_id"   # core re-export
output "bucket_arn"  # core re-export
output "mirror_url"  # REST endpoint, trailing slash
# + security_baseline, bucket_policy_json, lifecycle_rule_ids,
#   logging_target, logging_prefix (family test windows)
```

No changes to any existing module's interface (the core edit is
validation-only, invisible to conforming callers).

## Data Model

None beyond S3 bucket configuration. Object layout is owned by the
sluice mirror CLI (workstream 1).

## Testing Strategy

Family pattern throughout (`mock_provider` plan suites are the
gate; no divergence except the sandbox run):

**Plan suite (`tests/`, the gate):**

- Baseline suite: the shared `security_baseline.tftest.hcl`
  **variant** asserting SSE-S3 (`sse_algorithm == "AES256"`,
  `bucket_key_enabled == false`, `kms_key_arn == null`) with
  versioning `Enabled` — the second axis of the documented-variant
  matrix (access-logs = AES256 variant, evidence = versioning
  variant, mirror = both). Header comment names the divergences;
  excluded from the byte-identical diff loop (DESIGN-0022 §
  Baseline suite treatment).
- Policy suite: all four statements asserted **statement-by-
  statement from `jsondecode(bucket_policy_json)`** (never string
  matching): allow sid present with `Principal "*"`,
  `GetObject`, objects-only resource, `aws:SourceVpce` values ==
  `vpc_endpoint_ids`; baseline denies present;
  `DenyObjectDeletion` unconditional when break-glass empty +
  conditional (`StringNotEquals aws:PrincipalArn`) when set;
  `DenyPolicyMutation` conditional on the admin list. Additive
  merge run (operator statement coexists) + reserved-sid guard
  runs per OQ 2's resolution.
- Rejection runs, each verified per-rule (IMPL-0020 discipline —
  `expect_failures` proves the object errored, not which rule
  fired; message-probe or mutation per run): empty
  `vpc_endpoint_ids`, malformed vpce id, empty
  `policy_admin_principal_arns`, wildcard/malformed/duplicate
  principal ARNs, `kms_key_arn` with SSE-S3 (core precondition),
  reserved-sid collisions, `object_lock_retention_days` set with
  `enable_object_lock = false` (core coherence guard — free).
- `mirror_url` run: exact equality incl. trailing slash (composed
  from the mock-time-known bucket name + region).
- Lifecycle run: IA rule id present with the configured days when
  set, absent when `null` (via `lifecycle_rule_ids`).
- Logging runs: explicit target + prefix default
  (`<composed-name>/`), `null` target = no logging resource.

**Community apply (`tests-localstack/`, token-free 4.4,
`SERVICES=s3,sts`):** config-surface only per the F6 probe
discipline — versioning Enabled, AES256, policy attaches,
logging target/prefix round-trip. Fixture seeds the logging
target as a plain bucket (no sink-module dependency — the
explicit-target posture means the fixture owns its target).
Writes **no objects** when lock is enabled (COMPLIANCE teardown
discipline from IMPL-0021 probe B).

**Sandbox policy-evaluation run (opt-in, real AWS):** anonymous
GET via a VPCE succeeds / fails without one; delete denied with
empty break-glass; `PutBucketPolicy` denied outside the admin
list. Harness is OQ 8 — the one genuinely new test shape in this
design (nothing in the family evaluates live policy semantics
today).

## Phases

### Phase 1: Module scaffold + policy composition

- [ ] Scaffold `modules/s3/mirror-bucket` (naming per OQ 3,
      globals per OQ 4, pinned versioning + SSE-S3)
- [ ] Root `locals` composing the four statements (count-gated
      delete-deny) + core wiring + outputs incl. `mirror_url`
- [ ] Reserved-sid treatment per OQ 2 (core one-liner + root
      mirror guard)
- [ ] Probe P0 (star-principal rendering); fallback only if red

### Phase 2: Plan suite (the gate)

- [ ] Baseline variant suite + policy statement-by-statement
      suite + rejection runs with per-rule verification
- [ ] `mirror_url`, lifecycle, logging runs
- [ ] `just static` green (fmt/validate/tflint/docs + conftest);
      `just changed` shows the new leaf in plan + community tiers

### Phase 3: Apply + sandbox proof

- [ ] Community apply suite + FINDINGS.md, run live
- [ ] Sandbox evaluation run per OQ 8, run live against a
      sandbox account, results recorded in FINDINGS.md
- [ ] READMEs (serving posture, break-glass runbook, brownfield
      note) + `docz update`

Success criteria: `just static` + s3 family plan fan-out green;
sandbox run proves VPCE-only anonymous reads and denied deletes;
sluice workstream 2 unblocked (`mirror_url` consumable by the
Atlantis `.terraformrc` cutover in rollout phase 5).

## Open Questions

> **All resolved 2026-09-15: 1a, 2a, 3a, 4a, 5a, 6a, 7a, 8a.**
> The Detailed Design above was already written to the recommended
> shapes — no amendments; the IMPL cuts directly from this doc.

### 1. Does `vpc_endpoint_ids` drive both the allow and the core DenyOutsideVpce?

The issue asks for the allow "alongside the opt-in
`DenyOutsideVpce` from `allowed_vpc_endpoint_ids`" — one list or
two is unspecified.

- **a. (Recommended) One list drives both** —
  `allowed_vpc_endpoint_ids = var.vpc_endpoint_ids`. The allow
  opens the read path, the deny closes everything else; a single
  list cannot express "allow via endpoint A but deny via
  endpoint A", so the two can never contradict. Zero new core
  surface.
- b. Two independent lists (`vpc_endpoint_ids` for the allow,
  `allowed_vpc_endpoint_ids` passed through separately) — lets
  the deploy path ride a VPCE that is denied to readers, but
  admits incoherent combinations (allow-listed endpoint missing
  from the deny's exception = reads denied despite the allow)
  that fail closed at apply-time with no plan signal.
- c. Allow only, no `DenyOutsideVpce` — smaller, but any
  future injected allow (OQ 7) or operator statement widens the
  read surface beyond the VPCE set with no backstop.
- Other: (your call)

### 2. How are the three mirror statement sids protected from operator shadowing?

> **Build note (IMPL-0025 Phase 1, 2026-09-15):** option `a` as
> specified is unimplementable — the mirror's own composed
> statements travel through `internal_policy_statements`, so a
> core-side rejection of those sids fails the mirror itself. The
> guard is placed at the **mirror root** (functionally option
> `b`'s placement, with a mechanism forcing it): the root
> `additional_policy_statements` validation rejects all seven
> reserved sids (three baseline + four mirror-composed), and the
> root `locals` merge is collision-free by construction. No core
> change; no family fan-out. Resolution stands recorded as 2a
> for the one-list / family-posture decisions that do hold, with
> this note as the placement correction.

The additive channel's guard covers only the three baseline sids
today. An operator `additional_policy_statements` entry reusing
`DenyObjectDeletion` would sit beside (or confuse suites about)
the module-composed statement.

- **a. (Recommended) Extend the core reserved list** with
  `AllowMirrorReadFromVPCE`, `DenyObjectDeletion`,
  `DenyPolicyMutation`, and mirror the extended guard onto the
  mirror root (the family's root-mirroring rule for
  `expect_failures` addressability). One-line core change, no-op
  for existing purpose modules (none use those sids), and
  shadowing becomes unrepresentable fleet-wide rather than
  merely rejected in one module.
- b. Guard only at the mirror root (leave the core list at
  three) — no `internal/**` diff, no family fan-out; but the
  guarantee is local lore rather than fleet posture, and a
  future module reusing those sids gets no protection.
- c. No guard — document the sids as reserved in prose only.
  Cheapest; repeats the pre-IMPL-0023 posture the security
  reviews have rejected twice (prose reserves nothing).
- Other: (your call)

### 3. What is the naming interface: family standard or a single `bucket_name`?

The issue says "`bucket_name` (via the family's `name_override`
hatch)" — the exact variable shape is unspecified.

- **a. (Recommended) Family standard** — `name` +
  `name_override` + `shard_prefix_enabled`, unchanged. The
  sluice-dictated mirror name arrives via `name_override`
  (externally-dictated names are exactly its use case); sandbox
  and future second-mirror stacks use composed naming. Zero
  convention drift, zero surprises in `just changed` / docs /
  fixtures.
- b. Single required `bucket_name` mapped straight to the
  core's `name_override` (static internal `name`) — matches the
  issue text literally, but abandons composed naming
  (account+region provenance suffix) and the shard hatch for
  every mirror stack, and makes this the only purpose module
  whose name input behaves differently.
- Other: (your call)

### 4. Which Terragrunt globals does the module declare?

The issue says "no fleet remote-state lookup". The core still
needs `account_id` + `region` for name composition either way.

- **a. (Recommended) `account_id` + `region` only.** No
  `remote_state_bucket`, `remote_state_bucket_region`,
  `deploy_role_name`, `account_name` — there is no read to feed
  them. Terragrunt injects its uniform input set regardless of
  use; undeclared inputs are ignored (IMPL-0015 Q6a), so the
  narrower declaration changes nothing in production and keeps
  the test var-file surface minimal.
- b. All six globals (family boilerplate) — uniform with
  `bucket`/`evidence-bucket`, but four inputs with no consumer
  invite exactly the "why does changing X do nothing" confusion
  the family has been removing.
- Other: (your call)

### 5. What is the Object Lock variable shape?

The issue specifies `enable_object_lock` (bool, default false) alongside
`object_lock_retention_days` — mode and years unmentioned.

- **a. (Recommended) The issue shape, mode pinned COMPLIANCE,
  days-only.** Maps to
  `object_lock = { enabled = var.enable_object_lock, mode = "COMPLIANCE", days = var.object_lock_retention_days }`.
  The mirror's threat is quiet content mutation; GOVERNANCE's
  bypass exists for lower-stakes tiers, and years-scale mirror
  retention is nobody's plan. The core's days-xor-years and
  coherence guards cover the shape unchanged.
- b. Evidence-style `retention` object (mode selectable,
  days-xor-years, duration required when enabled) — fuller
  control, but replays OQ 1a of DESIGN-0022 against a weaker
  case: mirror lock is an opt-in hardening step, not an
  evidence-compliance guarantee, and the selectable mode buys
  a bypass its threat model does not want.
- c. Pin lock on (evidence posture: always locked, duration
  required) — contradicts the issue's default-off and forces
  every mirror (including sandbox/throwaway mirrors) into
  COMPLIANCE retention.
- Other: (your call)

### 6. Does `DenyPolicyMutation` get an off-switch?

The issue says "(default on)" but lists no toggle variable.

- **a. (Recommended) Add `enable_policy_mutation_guard`
  (bool, default `true`).** A mis-scoped admin list with an
  always-on deny strands the stack permanently (nobody outside
  the list can amend the policy — including the fix). The
  toggle is the reviewed-PR escape hatch for that footgun;
  default-on keeps the shipped posture identical to the issue.
- b. Exactly as specified — always on, no toggle. Smallest
  surface; accepts the lockout risk (mitigated only by getting
  the admin list right the first time, with no recovery path
  if wrong).
- Other: (your call)

### 7. How is the cross-account publisher allow expressed?

The issue: "the GitHub OIDC publisher role is provisioned out
of band (same-account needs no bucket-policy grant;
cross-account adds one injected allow at the root)." Whether
"injected at the root" means a module variable or an operator
statement is unspecified.

- **a. (Recommended) Explicit
  `cross_account_publisher_principal_arns` (list, default `[]`)**
  injecting an `AllowCrossAccountPublisherWrite` statement
  (`PutObject` + `GetObject` + `ListBucket` scoped to this
  bucket, no deletes — mirroring sluice DESIGN-0002's
  write-only-no-delete publisher permissions). Same-account
  stays empty (no statement rendered); the grant is a reviewed
  input, not folklore in a downstream root module.
- b. No variable — cross-account publishers ride the generic
  `additional_policy_statements` channel. Zero new surface;
  but the publisher grant (the mirror's one expected
  cross-account relationship) is then undocumented at the
  interface, unvalidated (no ARN-shape checks), and invisible
  to the plan suite's publisher-specific runs.
- Other: (your call)

### 8. What harness runs the opt-in sandbox policy-evaluation proof?

Nothing in the family evaluates live policy semantics today
(LocalStack does not enforce BPA/Object Lock/policy
evaluation); this is the first sandbox-evaluated suite, so its
shape sets the precedent.

- **a. (Recommended) Shell runbook under
  `tests-sandbox/`** — `apply` the module with real creds,
  then `curl` (anonymous GET via the VPCE endpoint vs. direct —
  expect 200 vs. 403) + `aws s3api` (delete and
  `put-bucket-policy` as a non-admin — expect AccessDenied),
  then destroy. CI-ignored by path (never in the plan/community
  matrices), runnable by hand, no new toolchain. Assertions
  live outside Terraform because anonymous-HTTP + negative-IAM
  evaluation are not `terraform test` shapes.
- b. `terraform_data` + `local-exec` provisioners inside a
  sandbox `terraform test` dir — keeps one harness, but bakes
  workstation-network assumptions (VPCE reachability) into
  provisioners that re-run on every apply and taint on failure.
- c. Go libtftest suite (the `eks/cluster/test` precedent) —
  richest assertions, but revives a second toolchain for one
  module and inherits that suite's no-CI-coverage problem.
- Other: (your call)

## References

- **gh-121** — `feat(s3): new mirror-bucket purpose module per
  sluice DESIGN-0002` (this design's commissioning issue).
- **Sluice DESIGN-0002** — Provider Mirror Bucket Terraform
  Module (the upstream spec; publisher role + `publisher_role_arn`
  deliberately diverged from here — see Non-Goals).
- **Sluice roadmap** — workstream 2 (bucket module) runs fully
  in parallel with the CLI (workstream 1); feeds `mirror_url`
  into the rollout cutover (phase 5).
- DESIGN-0019 / IMPL-0018 / INV-0009 — family architecture,
  purpose-module ruling, additive injection, reserved-sid
  pattern, wrapper gotchas.
- DESIGN-0022 / IMPL-0021 / INV-0011 — Object Lock core
  capability, retention/expiration interplay, variant suites,
  `log_retention_days` fixed-rule precedent, COMPLIANCE probe B
  discipline.
- IMPL-0015 — six globals, uniform injection, account-scoped
  keys, `assume_role` reads.
- IMPL-0020 — coherence validations (silent-widening lesson),
  `expect_failures` per-rule verification discipline.
- IMPL-0022 — trust-input validation doctrine (separate blocks
  per rule).
- ADR-0020 — remote-state key contract (`s3` shape; no new rows).
