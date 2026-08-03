---
id: INV-0009
title: "S3 module family layout and security baseline"
status: Concluded
author: Donald Gifford
created: 2026-08-01
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0009: S3 module family layout and security baseline

**Status:** Concluded
**Author:** Donald Gifford
**Date:** 2026-08-01

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [F1 — Architecture: purpose modules beat both the wide wrapper and the bucket-type discriminator](#f1--architecture-purpose-modules-beat-both-the-wide-wrapper-and-the-bucket-type-discriminator)
  - [F2 — The security baseline every bucket module ships by default](#f2--the-security-baseline-every-bucket-module-ships-by-default)
  - [F3 — The access-logs bucket is a forced exception to its own baseline](#f3--the-access-logs-bucket-is-a-forced-exception-to-its-own-baseline)
  - [F4 — The access-logging consumption contract is a tri-state](#f4--the-access-logging-consumption-contract-is-a-tri-state)
  - [F5 — The initial module catalog](#f5--the-initial-module-catalog)
  - [F6 — LocalStack tiers: almost everything is Community (probes RESOLVED)](#f6--localstack-tiers-almost-everything-is-community-probes-resolved)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Open Questions](#open-questions)
  - [1. Which architecture does the family use?](#1-which-architecture-does-the-family-use)
  - [2. What is the ADR-0020 state-key shape for s3?](#2-what-is-the-adr-0020-state-key-shape-for-s3)
  - [3. What variable shape does the consumer-side access-logging contract take?](#3-what-variable-shape-does-the-consumer-side-access-logging-contract-take)
  - [4. What is the default encryption mode?](#4-what-is-the-default-encryption-mode)
  - [5. How much CloudFront does the origin-bucket module own?](#5-how-much-cloudfront-does-the-origin-bucket-module-own)
  - [6. What shape does the VPCE-only policy restriction take?](#6-what-shape-does-the-vpce-only-policy-restriction-take)
  - [7. What bucket-naming convention guarantees global uniqueness?](#7-what-bucket-naming-convention-guarantees-global-uniqueness)
  - [8. What is the build order?](#8-what-is-the-build-order)
- [References](#references)
<!--toc:end-->

## Question

How should an S3 module family under `modules/s3/` be shaped? The recurring
tension with low-level resources: either one module wraps **all** the
options (the RDS-style wide wrapper, painful for a resource whose provider
surface is ~20 sub-resources), or the fleet grows many purpose-shaped,
easy-to-consume modules (`s3/access-logs-bucket`, `s3/events-bucket`, ...)
that each duplicate the common security core. A third shape — one module
with a `bucket_type` discriminator selecting per-type behavior plus a typed
config object per type — sits in between. Which one fits this fleet, given
the Terragrunt one-stack-one-module model and the standing
no-module-in-module rule (which the operator is willing to bend if
copy-paste gets out of hand)?

Secondary questions: what security baseline does **every** bucket ship with
by default, and how do all other bucket modules discover the per-region
access-logs bucket (default remote-state lookup, disableable, overridable)?

## Hypothesis

1. Purpose modules with a small, deliberately duplicated security core win.
   The fleet already runs this pattern (`rds/instance` forks `serverless`;
   IMPL-0017 ported one surface verbatim to three modules and pinned it with
   identical plan tests) — duplication is kept honest by contract tests, not
   by indirection.
2. The access-logs lookup is a tri-state consumer variable riding the
   ADR-0020 key contract: enabled-with-default-lookup (compose the
   conventional key), enabled-with-override (explicit bucket), or disabled.
3. Nearly the whole family is LocalStack-Community testable (S3, SQS, SNS,
   EventBridge are Community; only CloudFront is Pro), so the apply tier is
   cheaper than the RDS fleet's.

## Context

**Triggered by:** planning the first storage-tier modules. The pain: wide
wrappers of low-level resources reproduce the provider's entire surface (the
RDS modules flirt with this), while per-purpose modules multiply copy-paste.
The operator sketched a possible middle: `bucket_type = "access-logs"` with
a per-type config object accepted only when the type matches.

House constraints that bound the answer:

- **Terragrunt one-stack-one-module** (ADR-0001, ADR-0020): every live-repo
  folder instantiates exactly one module and its folder path IS the state
  key. Any architecture must keep one consumable module per bucket stack.
- **No module-in-module references** (standing rule, Gruntwork-style flat
  composition) — negotiable per the operator only if the alternative is
  excessive duplication.
- **ADR-0020** now governs cross-module remote-state reads: a new `s3` shape
  needs a key template, plan-suite `config.key` assertions, and README
  contract sections from day one.
- Since AWS provider v4, `aws_s3_bucket` is decomposed into ~20 companion
  resources (`aws_s3_bucket_policy`, `_versioning`,
  `_server_side_encryption_configuration`, `_public_access_block`,
  `_ownership_controls`, `_lifecycle_configuration`, `_logging`,
  `_cors_configuration`, `_notification`, `_website_configuration`, ...). A
  wrap-everything module is therefore strictly worse than it was in the RDS
  era.

## Approach

1. Desk-compare the four candidate architectures against the fleet's
   constraints and precedents; quantify the actual copy-paste cost of the
   purpose-module shape. *(Done — F1.)*
2. Enumerate the default-on security baseline from current AWS guidance
   (PAB, ownership, TLS-only, encryption, lifecycle hygiene). *(Done — F2.)*
3. Establish the AWS-side constraints on the access-logs target bucket that
   force baseline exceptions. *(Done — F3.)*
4. Shape the consumer-side access-logging contract on ADR-0020. *(Done —
   F4.)*
5. Catalog the initial module set and each one's type-specific surface.
   *(Done — F5.)*
6. Map the family onto LocalStack tiers; **probe (pending)** the two
   fidelity unknowns: does LocalStack Community actually *deliver* server
   access logs to the target bucket, and do bucket notifications fire into
   SQS/EventBridge under `terraform test`? *(F6.)*

## Environment

| Component | Version / Value |
|-----------|----------------|
| AWS provider | `~> 6.2` (resolving 6.5x) |
| Terraform | `>= 1.1` (fleet floor; no ephemeral/write-only need here) |
| LocalStack | Community for S3/SQS/SNS/EventBridge; Pro only for CloudFront |
| Modules in scope | new `modules/s3/*` family; `network/vpc-lookup` untouched |

## Findings

### F1 — Architecture: purpose modules beat both the wide wrapper and the bucket-type discriminator

Comparing the four shapes against the fleet's constraints:

| Shape | Verdict | Why |
|---|---|---|
| One wide wrapper ("all the options") | Rejected | Reproduces ~20 provider sub-resources behind one interface; every consumer sees every knob; the exact pain that triggered this INV. Worse than RDS because S3's surface is broader and flatter. |
| One module + `bucket_type` discriminator | Workable but not recommended | It is the wide wrapper in disguise: the module still contains the **union** of all type behavior, `count`-gated per type. HCL has no tagged unions, so every type's config object must exist as a nullable variable plus a precondition rejecting mismatched combinations (`bucket_type = "events"` with a CloudFront config set, etc.). Every new type or type fix replans and re-releases **all** bucket stacks of all types; the plan-test matrix multiplies (types x baseline cases). `rds/proxy`'s `target_type` works because it selects one key segment — not whole resource sets. |
| Thin purpose modules over an internal `s3/internal/core` module | Viable, violates a standing rule | Terragrunt never sees the nesting (one purpose module per stack still holds), so the rule here is stylistic, not structural. One level of nesting bounded to one service dir is the strongest case the rule will ever meet — but the duplication it would remove is small (see below), so it is not worth the precedent. |
| Purpose modules with a duplicated security core | **Recommended** | Matches the fleet's fork-and-diverge precedent (`instance` forked `serverless`; IMPL-0017 ported one identical surface to three modules). Kept honest the same way: an identical `security_baseline.tftest.hcl` in every module pinning the baseline (PAB on, TLS-only deny present, encryption mode, ownership enforced), so drift between copies fails CI, not a deploy. |

The quantified copy-paste: the security core is roughly **six resources plus
one policy-document local** (bucket, public-access block, ownership
controls, encryption config, policy, lifecycle hygiene rule; versioning is
per-module anyway) — ~150-200 lines. That is the same order as the RDS
modules' shared scaffolding, which the fleet already maintains as copies
without incident. The swayed-if-too-much-copy-paste threshold is not met at
five modules; revisit (OQ 1c) if the family grows past ~8 siblings.

### F2 — The security baseline every bucket module ships by default

Every module in the family creates its bucket with this baseline; each line
is either fixed (not a variable) or default-on (overridable):

| Control | Default | Overridable? |
|---|---|---|
| `aws_s3_bucket_public_access_block` — all four flags | on | fixed |
| `aws_s3_bucket_ownership_controls` — `BucketOwnerEnforced` (ACLs disabled) | on | fixed (access-logs bucket exempt per F3) |
| Bucket policy: deny `aws:SecureTransport = false` (HTTPS-only) | on | fixed |
| Bucket policy: deny TLS below 1.2 (`s3:TlsVersion`) | on | fixed |
| Bucket policy: VPCE-only deny (`aws:SourceVpce`) | off | opt-in (OQ 6) |
| Encryption: SSE-KMS with the AWS-managed `aws/s3` key + `bucket_key_enabled = true` | on | CMK override via `kms_key_arn` (BYO pattern, mirrors RDS) |
| Versioning | **off** (operator requirement) | `versioning_enabled = true` |
| Lifecycle: `abort_incomplete_multipart_upload` after 7 days | on | days configurable |
| `force_destroy` | false | overridable |
| Tags on every resource | — | `var.tags` |

Notes recorded, not litigated: CIS/Security Hub benchmarks nudge versioning
default-on; the fleet default is off by explicit operator decision (cost +
the RDS posture of opting into durability per stack), and each module README
says so. The `aws/s3` managed key cannot be policy-edited or used
cross-account — cross-account consumers (a CloudFront OAC in another
account, replication later) need the CMK override; the READMEs carry that
caveat.

### F3 — The access-logs bucket is a forced exception to its own baseline

AWS constraints on a server-access-logging **target** bucket, all of which
shape `s3/access-logs-bucket`:

1. **Same region as the source bucket** — this is why the design is a
   per-region singleton and why the default lookup composes a region-scoped
   key (the region is already a segment of every ADR-0020 key).
2. **SSE-S3 only.** S3 log delivery does not write to SSE-KMS targets — the
   one bucket in the family that cannot take the F2 KMS default (no CMK
   override either). Fixed to `AES256`, documented as the exception.
3. **Bucket policy grants the log-delivery service principal**
   (`logging.s3.amazonaws.com`) `s3:PutObject`, conditioned on
   `aws:SourceAccount` (and optionally source-bucket ARNs) so any bucket in
   the account can point at it without per-source policy edits.
4. Versioning off (log objects are append-only noise to version) and a
   default expiration lifecycle (90 days, configurable) so the bucket does
   not grow unbounded.
5. It logs nowhere itself (no self-logging loop) — its own `access_logging`
   surface is absent, another deliberate asymmetry with its consumers.

### F4 — The access-logging consumption contract is a tri-state

Every non-access-logs module carries one object variable:

```hcl
variable "access_logging" {
  type = object({
    enabled       = optional(bool, true)
    target_bucket = optional(string) # null = remote-state lookup
    prefix        = optional(string) # null = "<name>/"
  })
  default = {}
}
```

- `enabled = true, target_bucket = null` (the default): the module reads the
  per-region access-logs bucket from remote state at the ADR-0020 key
  (shape per OQ 2) and wires `aws_s3_bucket_logging` to it. A missing
  producer fails the plan with the documented loud-but-vague
  `Unable to find remote state` (the module README's contract section names
  the expected key, per ADR-0020 practice).
- `enabled = true, target_bucket = "explicit-name"`: no remote-state read;
  log to the named bucket.
- `enabled = false`: no logging resource, no remote-state read (the data
  source must be count-gated so disabled stacks never dial S3 for state).

The count-gated `data.terraform_remote_state` is the one new mechanical
pattern this family adds to ADR-0020 (all 12 existing reads are
unconditional); the key-template plan assertion covers the enabled path and
a second run asserts the disabled path composes no read.

### F5 — The initial module catalog

| Module | Purpose | Type-specific surface beyond F2 |
|---|---|---|
| `s3/access-logs-bucket` | The per-region log sink every other module points at (producer of the OQ-2 contract) | F3's exceptions; emits `bucket_name`, `bucket_arn`, `bucket_id` |
| `s3/bucket` | The general-purpose secure bucket ("a bucket that is not a foot-gun") | Nothing — it IS the baseline + tri-state logging; the reference implementation the others fork |
| `s3/events-bucket` | Bucket that emits object events | `aws_s3_bucket_notification` with lists/flags for SNS topics, SQS queues, EventBridge (`eventbridge = true` is one bool); NB the notification resource is a **per-bucket singleton** — all destinations live in one resource, which is why this is its own type |
| `s3/cloudfront-origin-bucket` | Private origin behind CloudFront | OAC-shaped policy statement (`cloudfront.amazonaws.com` principal conditioned on `AWS:SourceArn` = distribution ARNs input); scope of the distribution itself is OQ 5 |
| `s3/presigned-transfer-bucket` | Staging bucket for presigned-URL upload/download flows (the "one-time-use link for an object" pattern — presigned URLs) | Presigned URLs are an SDK/IAM concern, not a bucket resource — this module encodes the conventions: CORS configuration input, short-expiry lifecycle on a staging prefix (24h-7d), tight policy; README documents that link minting happens in the app/IAM layer |

All five duplicate the F2 core; all except `access-logs-bucket` carry the F4
tri-state.

### F6 — LocalStack tiers: almost everything is Community (probes RESOLVED)

S3, SQS, SNS, and EventBridge are LocalStack Community; CloudFront is
Pro-only. So four of five modules get real Community applies (the cheap
tier, like `network/vpc-lookup`), and only `cloudfront-origin-bucket` needs
the Pro-gated split (plan suite as gate + `tests-localstack-pro/`), for
which the RDS quartet is the template. **Pending probe** (the F5-style
unknown to close before IMPL): on the pinned Community image —

1. does server-access-log **delivery** actually materialize objects in the
   target bucket (or is the logging configuration accepted but inert)?
2. do bucket notifications fire into SQS/EventBridge fast enough to assert
   in a `terraform test` apply run?

Either way the config surface applies cleanly (plan suites gate it); the
probe only decides how deep the apply-tier assertions can go, recorded in
each FINDINGS.md like the IMPL-0017 parity note.

**Probe results (IMPL-0018, 2026-08-02/03, `localstack/localstack:4.4`).**
Both probes were run manually against the pinned image, and the answer to
each question is the opposite of the other:

1. **Log delivery — NEGATIVE.** LocalStack stores and round-trips the
   `PutBucketLogging` configuration faithfully, but never materializes
   delivered log objects: after 10 requests against a source bucket whose
   sink carried the exact `AllowS3ServerAccessLogDelivery` policy, the
   sink was still empty at 60 s and ~150 s, with no container-log
   activity. Real AWS is also best-effort with hours of latency, so
   delivery is untestable in a suite either way.
2. **Notification firing — POSITIVE.** An `s3:ObjectCreated:*` → SQS
   configuration delivered both the `s3:TestEvent` handshake and a full
   `ObjectCreated:Put` record (correct `configurationId`, bucket, key,
   size, eTag) within seconds.

**Consequence — the apply tiers assert the configuration surface in both
cases, but for different reasons.** For logging the *emulator* is the
limiter; for notifications the *harness* is (`terraform test` has no way
to receive an SQS message — there is no data source that reads a queue,
and pulling in the `external` provider would add a dependency to modules
that need none). A third, unplanned probe found LocalStack does **not**
enforce destination policies: registering a notification to a
policy-less queue succeeds, where real S3 returns `InvalidArgument`. So
the events-bucket apply *demonstrates* the required queue-policy shape
(in its fixture) without *verifying* it — the README section is the
contract. All three findings are recorded in the respective
`tests-localstack/FINDINGS.md` files.

## Conclusion

**Answer (OQs resolved 2026-08-01):** purpose modules over a shared
**internal core** at `modules/s3/internal/core`, consumed by relative path
so the core rides each purpose module's tag with no independent version to
drift (OQ 1 = c, conditional on the core never gaining a versioned source).
The family ships the F2 baseline (SSE-KMS `aws/s3` default with CMK
override, versioning off by default, HTTPS-only + TLS ≥ 1.2 deny, opt-in
VPCE-only policy), the F4 tri-state access-logging contract defaulting to a
remote-state lookup of the reserved flat key
`<account_name>/<region>/s3/access-logs/terraform.tfstate` with a
sending-bucket-name log prefix, and composed naming
`<name>-<account_id>-<region>` plus an opt-in 5-char random shard prefix.
Initial scope is three modules — `access-logs-bucket` + `bucket`, then
`events-bucket`; `cloudfront-origin-bucket` and `presigned-transfer-bucket`
stay cataloged but deferred. The two LocalStack fidelity probes ride the
first apply suite and block nothing at design time.

## Recommendation

Write one DESIGN doc for the family scoped to the internal core + the three
in-scope modules (baseline + contracts + catalog), then per-module IMPLs in
the OQ-8 order (`access-logs-bucket` + `bucket`, then `events-bucket`),
with the F6 probes riding the first apply suite. ADR-0020 gains the `s3`
shape row (general `s3/<stack-name>`, reserved `s3/access-logs`), and each
new module ships its key assertions + README contract section from the
first commit. The deferred modules get their own build-order call when
picked up.

## Open Questions

> **Resolved 2026-08-01:** 1 = **c** (internal core, version-drift concern
> answered structurally below), 2 = flat reserved path per the operator's
> live layout, 3 = **a modified** (prefix defaults to the sending bucket's
> name), 4 = **a**, 5 = **deferred** (module deferred), 6 = **a**,
> 7 = **a + opt-in shard prefix**, 8 = **a modified**
> (`cloudfront-origin-bucket` and `presigned-transfer-bucket` deferred —
> they stay cataloged in F5 with build order TBD when picked up).

### 1. Which architecture does the family use?

**Resolved (c).** The no-nesting rule is bent one level for `modules/s3/`
only, because the version-mismatch pain that motivates the rule cannot
occur here: the purpose modules consume the core via **relative path**
(`source = "../internal/core"`), which Terraform resolves inside the same
cloned ref of this repo. The live repo pins
`//modules/s3/<purpose>?ref=<tag>`, and the core rides that identical tag —
there is no independent core version to bump, so core/consumer drift is
structurally impossible. Renovate keeps its existing job (ref bumps in the
live repo); no extra sync tooling is needed. **Condition:** the core must
never gain a versioned source (registry / git-ref); if it ever does, this
resolution is void and (a)'s duplicated-core shape applies. The per-module
`security_baseline.tftest.hcl` stays regardless — it pins each purpose
module's *composed result*, guarding against a core change silently
altering a sibling's baseline.

- a) Purpose modules with a deliberately duplicated security core, pinned
  by an identical `security_baseline.tftest.hcl` per module (F1; the
  fleet's fork-and-diverge precedent).
- b) Single module with a `bucket_type` discriminator + nullable per-type
  config objects (the union-in-disguise; F1 row 2).
- **c) (Chosen)** Thin purpose modules over one internal
  `s3/internal/core` module — one-level nesting, relative-path source.
- d) One wide wrapper module.

### 2. What is the ADR-0020 state-key shape for s3?

**Resolved (flat, reserved well-known path — the operator's written live
layout is authoritative).** The access-logs singleton lives at
`live/<account>/<region>/s3/access-logs/terragrunt.hcl`, so the F4 lookup
composes exactly:

```text
<account_name>/<region>/s3/access-logs/terraform.tfstate
```

(no extra `<name>` segment — this supersedes the `default` sub-segment
sketched in (a); the opinionated fixed path is deliberate, so every bucket
stack under `live/<account>/<region>/s3/` gets logging by default with zero
configuration). General bucket stacks key as
`<account_name>/<region>/s3/<stack-name>/terraform.tfstate`, with
`access-logs` the one reserved stack name. ADR-0020's table gains both
rows; the consumer plan suites pin the composed access-logs key.

A **non-default log sink** needs no key-shape support: it is just another
stack of the same `access-logs-bucket` module deployed at its own
`s3/<stack-name>` with overridden vars, and any consumer that wants it
points there via the OQ-3 `target_bucket` override instead of the default
lookup. The reserved path only defines what "zero configuration" means.

- a) `s3/<type>/<name>` mirroring `rds/<type>/<name>` — e.g.
  `<account>/<region>/s3/access-logs/default/terraform.tfstate`.
- **b) (Chosen, as written above)** Flat `s3/<name>` with `access-logs` as
  a reserved name.

### 3. What variable shape does the consumer-side access-logging contract take?

**Resolved (a, modified).** The single tri-state object stands, with the
defaults pinned as: `enabled` — default **true**, disableable;
`target_bucket` — default **null = remote-state lookup** at the OQ-2 key,
overridable with an explicit bucket name (no remote-state read when
overridden); `prefix` — default **the sending bucket's composed name**
(the OQ-7 result, e.g. `<shard->-<name>-<account_id>-<region>/`, trailing
slash) so the access-logs bucket self-organizes by source, overridable.

- **a) (Chosen, with the defaults above)** The single tri-state object of
  F4 — one variable, three states, count-gated remote-state read.
- b) Two flat variables (`access_logging_enabled` bool +
  `access_logs_bucket_override` string) — same semantics, noisier surface.
- c) Always-on with override, no disable — strictest, but breaks
  bootstrapping (the access-logs bucket must exist before any other bucket
  in a new region) and F3 needs the exemption anyway.

### 4. What is the default encryption mode?

**Resolved (a).**

- **a) (Chosen)** SSE-KMS with the AWS-managed `aws/s3` key +
  `bucket_key_enabled = true`, CMK override via `kms_key_arn` (the stated
  requirement; mirrors the RDS BYO-KMS pattern). Access-logs bucket exempt
  (F3: SSE-S3 forced).
- b) SSE-S3 (`AES256`) default with SSE-KMS opt-in — simpler and free, but
  loses the CloudTrail-visible key-usage audit trail the KMS default buys.

### 5. How much CloudFront does the origin-bucket module own?

**Deferred (2026-08-01).** The `cloudfront-origin-bucket` module itself is
deferred (with `presigned-transfer-bucket`); both stay cataloged in F5 and
this OQ is decided when the module is picked up.

- a) Bucket side only: the module accepts
  `cloudfront_distribution_arns` and emits the OAC-ready policy; the
  distribution itself is a future `modules/cloudfront/` concern (keeps the
  service-dir boundary, keeps this module plan-testable for the policy
  shape without the Pro tier).
- b) Distribution + OAC in-module — one-stop but crosses service
  boundaries, drags the whole module to the Pro tier, and couples bucket
  releases to CloudFront surface churn.

### 6. What shape does the VPCE-only policy restriction take?

**Resolved (a).**

- **a) (Chosen)** Opt-in explicit list: `allowed_vpc_endpoint_ids`
  (default `[]` = no restriction); non-empty adds a
  deny-unless-`aws:SourceVpce`-in-list statement. No coupling to
  `vpc-lookup` remote state (an S3 gateway endpoint id is not part of that
  contract), and the README carries the standard caveat that it locks out
  console/non-VPCE access — including the deployer role unless the deploy
  path rides the VPCE.
- b) Derive the endpoint from `network/vpc-lookup` remote state — would
  require adding a `vpc_endpoint_ids` output to that contract first
  (contract change: ADR-0020 row, reference-vpc fixture, 68 override_data
  stubs) for marginal convenience.

### 7. What bucket-naming convention guarantees global uniqueness?

**Resolved (a, plus an opt-in shard prefix).** Default composed name
`<name>-<account_id>-<region>` with the `name_override` escape hatch, and
an explicit opt-in (`shard_prefix_enabled`, default false) that prepends a
5-character `random_string` (lowercase alphanumeric, kept stable via the
resource's lifecycle) for key-distribution/sharding purposes:
`<shard-prefix>-<name>-<account_id>-<region>`. The `random` provider joins
the family's `required_providers` (a first for the fleet's modules); the
63-char validation accounts for the extra 6 characters when the shard
prefix is enabled.

- **a) (Chosen, with the shard-prefix addition)**
  `<name>-<account_id>-<region>` composed by the module (S3 names are a
  global namespace; the account+region suffix makes fleet collisions
  structurally impossible and encodes provenance), with a `name_override`
  escape hatch for externally-dictated names. 63-char limit enforced by
  validation.
- b) Caller-supplied verbatim name only — simplest, but every consumer
  reinvents uniqueness and collisions surface as apply-time
  `BucketAlreadyExists`.

### 8. What is the build order?

**Resolved (a, modified).** `access-logs-bucket` + `bucket` first
(producer of the F4 contract + the reference consumer of the core), then
`events-bucket`. `cloudfront-origin-bucket` and
`presigned-transfer-bucket` are **deferred** — they remain in the F5
catalog, but their build order and OQ-5 scope are TBD when they are picked
up. The F6 probes ride the first apply suite.

- **a) (Chosen, trimmed to three modules)** `access-logs-bucket` +
  `bucket` first, then `events-bucket` — each as its own IMPL, with the F6
  probes riding the first apply suite.
- b) All five in one IMPL — one review, but a large blast radius and the
  probe learnings cannot feed the later modules.

## References

- ADR-0001 — cross-module composition via remote state
- ADR-0020 — remote-state key contract (the `s3` shape lands there)
- IMPL-0017 — the ported-identical-surface + identical-plan-tests precedent
  the duplicated security core reuses
- DESIGN-0010 / `rds/proxy` — the `target_type` discriminator precedent
  (selects a key segment, not resource sets)
- `network/vpc-lookup` — the Community-apply test-tier precedent
- AWS docs: S3 server access logging target constraints (same-region,
  SSE-S3-only, `logging.s3.amazonaws.com` grant); S3 Block Public Access;
  Object Ownership / `BucketOwnerEnforced`; presigned URLs
