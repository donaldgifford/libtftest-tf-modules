---
id: INV-0009
title: "S3 module family layout and security baseline"
status: Open
author: Donald Gifford
created: 2026-08-01
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0009: S3 module family layout and security baseline

**Status:** Open
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
  - [F6 — LocalStack tiers: almost everything is Community (probe pending)](#f6--localstack-tiers-almost-everything-is-community-probe-pending)
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

### F6 — LocalStack tiers: almost everything is Community (probe pending)

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

## Conclusion

**Answer:** pending OQ resolutions. The desk findings all point one way:
purpose modules with a contract-tested duplicated core, a tri-state
access-logging contract on a new ADR-0020 `s3` shape, and a
mostly-Community test tier. The two LocalStack fidelity probes are the only
unknowns and neither blocks design.

## Recommendation

Resolve the OQs, then split the work docz-style: one DESIGN doc for the
family (baseline + contracts + catalog), then per-module IMPLs starting
with the OQ-8 order. ADR-0020 gains the `s3` shape row, and each new module
ships its key assertions + README contract section from the first commit.

## Open Questions

### 1. Which architecture does the family use?

- **a) (Recommended)** Purpose modules with a deliberately duplicated
  security core, pinned by an identical `security_baseline.tftest.hcl` per
  module (F1; the fleet's fork-and-diverge precedent).
- b) Single module with a `bucket_type` discriminator + nullable per-type
  config objects (the union-in-disguise; F1 row 2).
- c) Thin purpose modules over one internal `s3/internal/core` module —
  bends the no-nesting rule one level; revisit if the family grows past ~8
  siblings and copy-paste drift bites despite the contract tests.
- d) One wide wrapper module.

### 2. What is the ADR-0020 state-key shape for s3?

- **a) (Recommended)** `s3/<type>/<name>` mirroring the `rds/<type>/<name>`
  precedent — e.g.
  `<account>/<region>/s3/access-logs/default/terraform.tfstate`, with
  `default` as the conventional singleton name the F4 lookup composes (a
  second access-logs bucket for a special case is just another `<name>`).
  Live-repo folder = key, per ADR-0020.
- b) Flat `s3/<name>` with `access-logs` as a reserved name — one segment
  shorter but collapses the type namespace and makes the reserved-name rule
  implicit.

### 3. What variable shape does the consumer-side access-logging contract take?

- **a) (Recommended)** The single tri-state object of F4 (`enabled` /
  `target_bucket` / `prefix`, default = enabled + lookup) — one variable,
  three states, count-gated remote-state read.
- b) Two flat variables (`access_logging_enabled` bool +
  `access_logs_bucket_override` string) — same semantics, noisier surface.
- c) Always-on with override, no disable — strictest, but breaks
  bootstrapping (the access-logs bucket must exist before any other bucket
  in a new region) and F3 needs the exemption anyway.

### 4. What is the default encryption mode?

- **a) (Recommended)** SSE-KMS with the AWS-managed `aws/s3` key +
  `bucket_key_enabled = true`, CMK override via `kms_key_arn` (the stated
  requirement; mirrors the RDS BYO-KMS pattern). Access-logs bucket exempt
  (F3: SSE-S3 forced).
- b) SSE-S3 (`AES256`) default with SSE-KMS opt-in — simpler and free, but
  loses the CloudTrail-visible key-usage audit trail the KMS default buys.

### 5. How much CloudFront does the origin-bucket module own?

- **a) (Recommended)** Bucket side only: the module accepts
  `cloudfront_distribution_arns` and emits the OAC-ready policy; the
  distribution itself is a future `modules/cloudfront/` concern (keeps the
  service-dir boundary, keeps this module plan-testable for the policy
  shape without the Pro tier).
- b) Distribution + OAC in-module — one-stop but crosses service
  boundaries, drags the whole module to the Pro tier, and couples bucket
  releases to CloudFront surface churn.

### 6. What shape does the VPCE-only policy restriction take?

- **a) (Recommended)** Opt-in explicit list: `allowed_vpc_endpoint_ids`
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

- **a) (Recommended)** `<name>-<account_id>-<region>` composed by the
  module (S3 names are a global namespace; the account+region suffix makes
  fleet collisions structurally impossible and encodes provenance), with a
  `name_override` escape hatch for externally-dictated names. 63-char limit
  enforced by validation (name up to 37 chars after the 26-char suffix).
- b) Caller-supplied verbatim name only — simplest, but every consumer
  reinvents uniqueness and collisions surface as apply-time
  `BucketAlreadyExists`.

### 8. What is the build order?

- **a) (Recommended)** `access-logs-bucket` + `bucket` first (producer of
  the F4 contract + the reference baseline implementation the others fork),
  then `events-bucket`, then `cloudfront-origin-bucket`, then
  `presigned-transfer-bucket` — each as its own IMPL, with the F6 probes
  riding the first apply suite.
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
