---
id: INV-0011
title: "Platform hub module gaps across network, s3, secretsmanager, and eks"
status: In Progress
author: Donald Gifford
created: 2026-08-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0011: Platform hub module gaps across network, s3, secretsmanager, and eks

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-08-13

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [F1 — The hub context is external to this repo](#f1--the-hub-context-is-external-to-this-repo)
  - [F2 — Provider surface verification](#f2--provider-surface-verification)
  - [F3 — r53-lookup mirrors vpc-lookup](#f3--r53-lookup-mirrors-vpc-lookup)
  - [F4 — S3 Object Lock must enter through the core](#f4--s3-object-lock-must-enter-through-the-core)
  - [F5 — S3 lifecycle exposure needs a core type extension](#f5--s3-lifecycle-exposure-needs-a-core-type-extension)
  - [F6 — Secrets Manager external mode is the third content leg](#f6--secrets-manager-external-mode-is-the-third-content-leg)
  - [F7 — EKS cluster access is a count-gated SSO singleton](#f7--eks-cluster-access-is-a-count-gated-sso-singleton)
  - [F8 — Node group hardwires the secure class in five places](#f8--node-group-hardwires-the-secure-class-in-five-places)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Open Questions](#open-questions)
  - [1. How do we anchor the external hub design references?](#1-how-do-we-anchor-the-external-hub-design-references)
  - [2. How does this fan out into DESIGN docs?](#2-how-does-this-fan-out-into-design-docs)
  - [3. One zone per lookup instance, or a zone map?](#3-one-zone-per-lookup-instance-or-a-zone-map)
  - [4. Which state-key shape segment for zones?](#4-which-state-key-shape-segment-for-zones)
  - [5. What is the zone output contract?](#5-what-is-the-zone-output-contract)
  - [6. How does Object Lock enter the S3 family?](#6-how-does-object-lock-enter-the-s3-family)
  - [7. How do the baseline suite and outputs treat Object Lock?](#7-how-do-the-baseline-suite-and-outputs-treat-object-lock)
  - [8. What lifecycle surface does the bucket module expose?](#8-what-lifecycle-surface-does-the-bucket-module-expose)
  - [9. What shape is the externally-managed secret mode?](#9-what-shape-is-the-externally-managed-secret-mode)
  - [10. Does external mode seed a placeholder version?](#10-does-external-mode-seed-a-placeholder-version)
  - [11. What shape is the access-entries surface?](#11-what-shape-is-the-access-entries-surface)
  - [12. What is the private-endpoint posture toggle?](#12-what-is-the-private-endpoint-posture-toggle)
  - [13. What shape is the workload class input?](#13-what-shape-is-the-workload-class-input)
- [References](#references)
<!--toc:end-->

## Question

Which additions do the existing modules need, and which new modules must be
built, for the platform hub + spoke rollout — specifically: (1) a
`network/r53-lookup` producer for Route53 zones consumable by e.g. an
external-dns pod-identity role; (2) S3 Object Lock (evidence-grade retention
no admin can shorten) plus exposing the core's `extra_lifecycle_rules` at the
`s3/bucket` surface; (3) an externally-managed mode on `secretsmanager/secret`
(shell + policy + CMK wiring, never a value); (4) a generic `access_entries`
map plus a private-endpoint-only posture on `eks/cluster`; (5) a
parameterized `workload_class` on `eks/managed-node-group`?

## Hypothesis

All five land as additive changes to existing modules plus two new modules
(`network/r53-lookup`, an S3 evidence purpose module), with no breaking
change for existing consumers: every current default is preserved
(`workload_class = "secure"`, generated-secret mode, SSO surface untouched,
endpoint defaults untouched) and each area has an established in-fleet
pattern to fork (vpc-lookup, the S3 purpose-module family, the ECR
operator-placeholder pattern, count-gated singletons).

## Context

The platform hub design (external to this repo — see F1 and OQ 1) defines a
hub account/cluster with spoke clusters, hub principals
(argocd-deployer / provisioner / break-glass), workload groups
(core / observability / temporal / secure, its §2), and evidence-retention
requirements for Loki/audit data (its "RFC-0001 harness-removal problem" —
NOT this repo's RFC-0001; see F1). Serving that design from this fleet
surfaces gaps in five module areas. This INV maps each gap to its exact
insertion point and the constraints discovered, and queues the decisions.

**Triggered by:** the platform hub/spoke design (external); operator request
2026-08-13.

## Approach

1. Map the donor patterns and change sites in-repo: `network/vpc-lookup` +
   `eks/pod-identity-access` (for r53-lookup), `s3/internal/core` + the three
   purpose modules (for Object Lock + lifecycle), `secretsmanager/secret` +
   the ECR placeholder pattern (for external mode), `eks/cluster`
   access/endpoint surface, and `eks/managed-node-group` label/taint/gVisor
   wiring — including each module's test suites, since the suites pin today's
   behavior.
2. Verify every needed provider surface against the **actual pinned
   provider** via `terraform providers schema -json` (not docs) — the
   INV-0010 discipline.
3. Sweep docs/ for prior art and standing decisions each change must respect
   (INV-0004, DESIGN-0019/IMPL-0018, DESIGN-0020/IMPL-0019, DESIGN-0001/0002,
   IMPL-0001/0002, ADR-0002..0012, ADR-0015, ADR-0020) — and for the hub
   concepts themselves, to locate or rule out an in-repo referent.

## Environment

| Component | Version / Value |
|-----------|----------------|
| Terraform CLI (mise pin) | 1.15.8 |
| AWS provider constraint / resolved at probe | `~> 6.2` / 6.58.0 |
| Schema probe | `terraform providers schema -json`, 2026-08-13 |
| LocalStack Community pin (apply tiers) | 4.4 (token-free) |

## Findings

### F1 — The hub context is external to this repo

The hub design's vocabulary has **no referent in this repo**, verified by
grep across all of docs/:

- "hub" (platform sense), "spoke", "Thanos", "ClickHouse", "temporal",
  "WORM", "tamper", "harness-removal": **zero hits**. "Loki" appears once
  (ADR-0002:106, a future pod-identity consumer row). "provisioner" appears
  once (ADR-0011, a rejected local-exec alternative).
- **This repo's RFC-0001 is the module testing strategy** (terraform test as
  baseline, libtftest for runtime). It contains no audit / retention /
  evidence / compliance content. Its only "removal" concept is the
  no-fracture rule: a module migrating to libtftest **deletes its terraform
  test suite** — treated as a feature, not a problem. The "harness-removal
  problem" motivating the evidence bucket must therefore live in an
  **external** RFC-0001 (presumably the platform repo's), and this INV
  treats it as an external requirement, not an in-repo citation.
- The closest in-repo hooks the hub design does have: ADR-0002's future
  workload-roles table (Loki, external-dns), DESIGN-0002's original
  `external_dns_zone_ids` intent (moved to the pod-identity-access domain by
  IMPL-0001 Q3 and never built), and DESIGN-0002's original
  `endpoint_public_access = false` break-glass posture (flipped to `true` by
  IMPL-0001 Q11 — a recorded, deliberately-parked drift, DESIGN-0015
  Non-Goals).

Consequence: each follow-up DESIGN needs a citation convention for the hub
doc (OQ 1), and nothing in this INV may claim this repo's RFC-0001 as the
evidence-bucket motivation.

### F2 — Provider surface verification

Everything needed exists in the pinned provider (probed against the resolved
6.58.0 under `~> 6.2`):

| Surface | Present | Notes |
|---|---|---|
| `aws_s3_bucket.object_lock_enabled` | yes | create-time; toggling **replaces the bucket** |
| `aws_s3_bucket_object_lock_configuration` | yes | `rule.default_retention` = `mode` (GOVERNANCE \| COMPLIANCE) + `days` xor `years`; `token` attr for the AWS-support enable-on-existing path |
| `aws_eks_access_entry` | yes | `principal_arn`, `type`, `kubernetes_groups`, `user_name`, `tags` |
| `aws_eks_access_policy_association` | yes | `policy_arn`, `principal_arn`, `access_scope { type, namespaces }` |
| `aws_eks_cluster.vpc_config.public_access_cidrs` | yes | **not exposed by our module today** (F7) |
| `aws_eks_cluster.access_config` | yes | `authentication_mode`, `bootstrap_cluster_creator_admin_permissions` |
| `data.aws_route53_zone` | yes | args incl. `name`, `zone_id`, `private_zone`, `vpc_id`, `tags`; attrs incl. `arn`, `zone_id`, `name`, `name_servers`, `private_zone` |
| `data.aws_route53_zones` (plural) | yes | returns `ids` only — enough for an existence sweep, not for facts |
| lifecycle rule sub-blocks | yes | `transition` + `noncurrent_version_transition` exist alongside the expiration blocks the core already renders |

### F3 — r53-lookup mirrors vpc-lookup

`network/vpc-lookup` is the donor pattern and transfers nearly 1:1:

- **The pattern:** zero-resource, data-source-only producer; discovery by
  `tag:Name = var.name` with an explicit-ID override collapsing the tag
  filter (`vpc_lookup_tags = var.vpc_id != null ? {} : merge({...})`);
  sorted outputs for determinism; a small stable contract (2 outputs) plus
  additive facts; published at an ADR-0020 key the consumers compose. No
  validations, no preconditions; one count-gated data source
  (`lookup_internet_gateway`) because the data source errors when the thing
  is absent.
- **INV-0004 decisions an r53 sibling inherits:** contract-first (grep the
  consumers before designing outputs — for zones there are no consumers yet,
  so the contract is designed from the external-dns policy need);
  ship-the-read-only-adapter-first (permanently serves environments where
  Terraform must never own DNS); module path and state segment are
  independent (`network/vpc-lookup` publishes under `vpc/`).
- **The consumer:** `eks/pod-identity-access` expresses per-identity IAM as
  `inline_policies = map(string)` (JSON documents) plus two ARN-list
  channels. An external-dns grant is caller-composed JSON needing
  `route53:ChangeResourceRecordSets` / `route53:ListResourceRecordSets`
  scoped to `arn:aws:route53:::hostedzone/<id>` plus unscoped
  `route53:ListHostedZones` — i.e. the consumer needs **zone id and/or
  ARN** from remote state. DESIGN-0002's abandoned `external_dns_zone_ids`
  is the direct heritage; nothing Route53 exists anywhere in modules/ today.
- **Route53 wrinkles vs the VPC case:** zones are **global** (the ADR-0020
  key still embeds `<region>` — the deploying stack's folder region; OQ 4);
  private zones need `private_zone = true` (+ optionally `vpc_id`) on the
  data source for split-horizon pairs where public and private zones share
  a name; there is no subnet-tier analog, so the module is substantially
  smaller than vpc-lookup.
- **Testability:** Route53 is Community-tier in LocalStack — the vpc-lookup
  test recipe (plan suite with `mock_provider` + `override_data`; real
  Community apply against token-free 4.4 with `SERVICES=route53,sts`)
  transfers unchanged.

### F4 — S3 Object Lock must enter through the core

- **Standing decision:** DESIGN-0019 Non-Goals rules that Object Lock (and
  its ilk) enter as **new purpose modules, not new knobs** on
  `bucket`/`events-bucket` ("new needs mean new purpose modules"). IMPL-0018
  likewise lists it Out of Scope. An evidence bucket is net-new to the
  INV-0009 F5 catalog.
- **But the core still changes:** `object_lock_enabled` lives on
  `aws_s3_bucket`, which only the internal core owns. The core today sets no
  object-lock anything (grep: zero hits across `modules/s3/**`). So the
  design is: core gains a purpose-module-only `object_lock` input (default
  off/null — the attribute is create-time and **toggling replaces the
  bucket**, so existing buckets are untouched only if the default is a
  no-op) plus the `aws_s3_bucket_object_lock_configuration` resource, and a
  new `s3/evidence-bucket` purpose module pins it on.
- **Versioning coupling:** Object Lock requires versioning Enabled and
  forbids suspending it. The core's `versioning_enabled` false-branch is
  `"Suspended"`; nothing couples the two today — the core needs a
  precondition (object lock ⇒ versioning enabled).
- **Retention semantics:** COMPLIANCE mode = no principal, including root
  and hub admins, can shorten retention or delete a locked version until
  expiry — exactly the "admins cannot shorten" requirement; GOVERNANCE is
  bypassable via `s3:BypassGovernanceRetention`. Default retention (mode +
  days/years) applies to new object versions; lifecycle expiration on
  locked versions is deferred by S3 until retention passes (a
  retention-vs-expiration interplay the DESIGN must document).
- **Baseline friction:** the shared `security_baseline.tftest.hcl` pins
  `versioning_status == "Suspended"`; an evidence bucket asserts
  `"Enabled"`, so it **cannot** be byte-identical to `s3/bucket`'s canonical
  copy — it is a documented variant (the access-logs F3-variant precedent)
  or the static-check §5 diff-guard grows a second reference (OQ 7).
  Likewise `security_baseline`'s object shape is shared by every family
  module — growing it with lock fields ripples into every suite (OQ 7).
- **LocalStack:** whether the pinned Community 4.4 *enforces* retention
  (deny-delete) is unprobed; family discipline (F6 probes 1–3 of IMPL-0018)
  is to assert the config surface in the suites and record the enforcement
  probe outcome in FINDINGS.md either way.

### F5 — S3 lifecycle exposure needs a core type extension

- The core's `extra_lifecycle_rules` type supports **only** `prefix`
  filtering + current-version expiration + noncurrent-version expiration.
  No `transition` / `noncurrent_version_transition` — but Thanos / Loki /
  ClickHouse tiering IS storage-class transitions, so exposing the type
  as-is at the `s3/bucket` surface would miss the stated point. The
  provider-side blocks exist (F2); the core's `dynamic "rule"` and the type
  both need the additive optional attributes.
- `s3/bucket` passes **nothing** to core's `extra_lifecycle_rules` today
  and does not re-export `lifecycle_rule_ids` — the only lifecycle
  assertion window purpose suites have (`access-logs-bucket` re-exports it
  precisely for that). Exposure = new typed variable + pass-through + the
  output re-export.
- Precedent for the pass-through pattern: `access-logs-bucket` maps
  `log_retention_days` → a fixed-id core rule; and the reserved-sid
  validation-mirroring rule applies — any root-side validation must live on
  the root variable because `expect_failures` cannot target a child
  module's validation.
- Test-coverage note: the core's `extra_lifecycle_rules` dynamic is
  exercised by exactly one run (`encryption_logging.tftest.hcl`,
  expiration only); `noncurrent_version_expiration_days`, `enabled=false`,
  and `prefix` have zero coverage anywhere — the DESIGN should close that
  while extending the type.
- CI note: any core edit fans out — `scripts/changed-modules.sh` re-tests
  every s3 leaf module on `internal/**` diffs (by design).

### F6 — Secrets Manager external mode is the third content leg

- DESIGN-0020 OQ 1 resolved exactly two content shapes (generated bare /
  generated RDS-JSON) and **explicitly deferred** BYO-caller-value; the
  README's deferral list repeats it. "External" (no value at all — shell +
  policy + KMS only) is a third leg the design left open; INV-0010 OQ 3
  option c even names the pattern ("operator supplies the password
  out-of-band … module only references") — rejected for the RDS create
  mode, directly on-point here.
- **Mechanics are already probe-validated:** ephemeral blocks take
  `count`/`for_each`; INV-0010's probe module was literally a count-gated
  ephemeral → `secret_string_wo`, and F3 records "a `count = 0` ephemeral
  is simply never opened" under the real-provider pattern (the
  mock_provider limitation is type-level and this module already cannot use
  mock_provider). Shipping it would be the fleet's **first in-tree**
  count-gated ephemeral.
- **Insertion point:** gate `ephemeral "random_password"` and
  `aws_secretsmanager_secret_version.this` off together; the secret shell,
  `read_principals` policy, KMS wiring (managed default / BYO CMK /
  faithful-null output), `name_prefix`, recovery window, and the ADR-0020
  `secrets` key shape all apply unchanged — external consumers (ArgoCD git
  credentials, OIDC client secrets) read the same pointer contract.
- **Contract friction:** `outputs_contract.tftest.hcl` pins the six-output
  set by name, and two outputs are generation-mode echoes
  (`secret_string_version`, `username`) whose semantics go null/meaningless
  in external mode — the established faithful-null precedent
  (`kms_key_arn`) fits (fold into OQ 9). The `default.tftest.hcl` no-leak
  assertion stays valid in both modes (a plan with no version resource
  trivially has no `secret_string_wo`); external mode needs its own runs
  (resource counts 0, unused-generation-knob guardrails).
- **Guardrail:** external mode + generation knobs set (`username`,
  non-default `password_length` / `password_override_special` /
  `secret_string_version`) should fail at plan — cross-variable, so a
  precondition (the fleet's `>= 1.11` floor here would allow
  cross-variable validations, but the precondition convention matches
  `rds/*` and `pod-identity-access`).
- **The no-version wrinkle:** with no seeded version, `GetSecretValue`
  fails until the provisioner writes one — consumers must tolerate ordering
  (or the mode seeds an ECR-style write-only placeholder; OQ 10). The
  conftest credential gate (`policy/credentials.rego`) constrains any
  placeholder to the `_wo` form — already the only legal path.

### F7 — EKS cluster access is a count-gated SSO singleton

- "SSO-only" is literal: one count-gated `aws_eks_access_entry.sso` + one
  `aws_eks_access_policy_association.sso`, principal resolved **inside**
  the module by IAM role regex `AWSReservedSSO_<sso_role_name>_*` (fails
  unless exactly one match). No arbitrary-principal path exists; the
  association's `access_scope` takes a bare type string (no `namespaces`
  argument even though scope type "namespace" would require one);
  `sso_cluster_policy` is allowlist-validated to three cluster-level
  policies. `authentication_mode` is hardcoded `"API_AND_CONFIG_MAP"`
  (IMPL-0001 Q8), and `bootstrap_cluster_creator_admin_permissions` is
  never set (provider default true applies silently — worth an explicit
  decision while in the file).
- A generic `access_entries` map (hub principals: argocd-deployer,
  provisioner, break-glass) is **additive on a clean seam**: `for_each`
  resources alongside the SSO pair leave existing resource addresses,
  tests (plan suite asserts the SSO counts by address), and consumers
  untouched. Direct principal ARNs (no regex resolution), per-entry type /
  groups / user_name, and a list of policy associations with full
  `access_scope { type, namespaces }`. EC2-style entry types
  (`EC2_LINUX` etc.) reject kubernetes_groups/associations — a validation
  concern for the DESIGN.
- **Endpoint posture:** `endpoint_private_access` (default true) and
  `endpoint_public_access` (default true per IMPL-0001 Q11 — a recorded
  flip of DESIGN-0002's original false-with-break-glass intent, parked as
  known drift by DESIGN-0015). `public_access_cidrs` is **absent from the
  module entirely** (provider default `0.0.0.0/0` when public is on).
  Private-only posture already exists mechanically
  (`endpoint_public_access = false`); the real gaps are the missing CIDR
  hook and a guard that at least one endpoint stays enabled (OQ 12).
  The plan suite pins both endpoint defaults — default changes are
  test-visible and consumer-breaking.

### F8 — Node group hardwires the secure class in five places

The secure class is literal in **five** sites that a `workload_class` input
must thread through together:

1. `locals.tf` `runtime_labels`: `"workload-class" = "secure"` +
   `"runtime" = "gvisor"` (merged with `additional_labels`).
2. `main.tf` static `taint` block: `workload-class=secure:NO_SCHEDULE`
   ("always-on" per DESIGN-0001; gvisor RuntimeClass tolerates it).
3. `templates/user_data.sh.tftpl` kubelet flags — the label list AND
   `--register-with-taints=workload-class=secure:NoSchedule` are **string
   literals in the template** (only `${k8s_arch}` is templated), spelled
   `NoSchedule` kubelet-side vs `NO_SCHEDULE` API-side.
4. The gVisor install: an **unconditional** shellscript part of the
   user-data MIME (download + SHA-512 verify + containerd drop-in +
   restart + plugin assert) — no toggle exists; only the ECR-mirror part
   is gated. Per-class gVisor means gating this whole part plus the
   `runtime=gvisor` label and its kubelet fragment.
5. `outputs.node_taints` re-hardcodes the taint literal (plus
   `additional_taints`), and two variable descriptions bake the wording.

Context that supports parameterizing: ADR-0005/0006 already describe a
multi-class world ("ineligible workloads stay on standard node groups under
runc") that this module simply never parameterized; the class taxonomy
(core / observability / temporal / secure) exists only in the external hub
doc §2 — no in-repo doc enumerates classes beyond "secure". Existing plan
suites assert the secure label/taint literally (set-iteration on the taint
block, label equality), so `workload_class = "secure"` as default preserves
every existing test and consumer; per-class behavior becomes a new test
matrix. Nothing asserts user-data content today — per-class gVisor gating
should bring the first user-data assertions with it.

## Conclusion

**Answer: Yes** — all five areas are achievable as additive changes plus two
new modules, with no breaking change for existing consumers, and every
needed provider surface verified present under the pin (F2). The
constraints that shape the designs: Object Lock is create-time (core input
must default to a no-op or existing buckets replace, F4); the evidence
bucket cannot share the byte-identical baseline suite (F4); tiering
requires extending the core lifecycle type, not just exposing it (F5);
external secret mode is the fleet's first in-tree count-gated ephemeral
with two mode-dependent outputs (F6); the cluster module lacks
`public_access_cidrs` entirely and silently inherits
`bootstrap_cluster_creator_admin_permissions = true` (F7); and the secure
node class is hardwired in five places including an untested user-data
template (F8). The hub design's requirements are real but external — this
repo has no hub/spoke/harness-removal referent, and this repo's RFC-0001 is
unrelated (F1).

## Recommendation

Resolve the open questions below, then fan out into DESIGN docs (OQ 2 for
the split) in this order: `network/r53-lookup` first (smallest, pure
producer, no existing-module risk, unblocks the external-dns pod-identity
worked example), then the S3 pair (one family DESIGN: evidence bucket +
lifecycle exposure — both touch the core, ride one core change), the
Secrets Manager external mode (small, pattern-established), and the two EKS
changes (access surface + endpoint posture; workload class). Each DESIGN
cites the hub doc per the OQ 1 convention.

## Open Questions

> **Resolved 2026-08-14: 2a, 4a, 5a, 6a, 7a, 8a, 9a, 10a, 11a; 1, 3, and
> 13 resolved with modifications; 12 remains open.**
>
> - **OQ 1 (Other — distill, don't just cite):** worth doing. The
>   hub/spoke model's module-relevant parts get pulled from the external
>   hub docs into this repo (operator will share them for review) rather
>   than cited blind — landing first as the EKS DESIGN's Context section,
>   promoted to a standalone reference doc only if it outgrows that.
> - **OQ 3 (a, plus the path):** one zone per instance, AND the module
>   lives at **`modules/dns/zone-lookup`** — a new `dns/` service
>   directory mirroring `network/vpc-lookup`'s naming, leaving sibling
>   room for a future create-mode `dns/zone` the way `network/` leaves
>   room for `network/vpc`. Path and state segment align (`dns/`).
> - **OQ 13 (a, modified — default flips to core):** enum
>   `{core, observability, temporal, secure}` + baked per-class rules +
>   nullable gVisor override as designed, but **`workload_class`
>   defaults to `"core"`**, and the plan suite must test BOTH the
>   core-default run AND an explicit `secure` run (secure is the
>   highest-stakes class to pin). **Consequence recorded:** today's
>   hardwired behavior IS secure, so a core default is a breaking default
>   change — existing node-group stacks that don't set the variable
>   would silently lose the taint + gVisor on upgrade. The DESIGN must
>   carry the major-bump + migration note (existing stacks pin
>   `workload_class = "secure"` before upgrading).
> - **OQ 12 stays open** pending the defaults discussion (what option a
>   changes vs today's surface).

### 1. How do we anchor the external hub design references?

The hub doc (its §2 workload groups, hub principals, its RFC-0001
"harness-removal problem") lives outside this repo (F1).

- **a. Cite it as an external reference (recommended).** Each follow-up
  DESIGN carries a "Hub design (external)" reference line with the specific
  requirement quoted/restated in that DESIGN's Context, and this INV records
  the requirement rows as given. No in-repo copy to drift.
- b. Import the hub doc (or the relevant excerpts) into docs/ here so
  citations are in-repo and versioned with the fleet.
- Other: (your call — e.g. link the platform repo path here.)

### 2. How does this fan out into DESIGN docs?

- **a. Four DESIGNs (recommended):** r53-lookup; S3 (evidence bucket +
  lifecycle exposure together — one core change, one family DESIGN, per the
  DESIGN-0019 precedent of family-level docs); secretsmanager external
  mode; EKS (both cluster changes + the node-group class in one DESIGN,
  since the hub cluster posture is one coherent story). Each independently
  implementable.
- b. Six DESIGNs — fully separate (r53 / s3-evidence / s3-lifecycle /
  sm-external / eks-cluster / node-class). Maximum independence, more doc
  overhead, the two s3 items would race on the same core files.
- c. Two DESIGNs — "new modules" (r53 + evidence bucket) and "existing
  module additions" (everything else). Fewer docs, but couples unrelated
  reviews.

### 3. One zone per lookup instance, or a zone map?

- **a. Single zone per instance (recommended).** Mirrors vpc-lookup
  exactly: `<name>` is the ADR-0020 triple-coupling (producer input ==
  live-repo folder == consumer input), one stack per zone, consumers
  needing N zones read N states (pod-identity-access callers compose N
  `data.terraform_remote_state` reads or a `for_each` over zone stack
  names). Smallest contract; split-horizon = two stacks (`public` /
  `internal` folder names).
- b. A `zones` map in one instance publishing `zone_ids` / `zone_arns`
  maps. One read for consumers, but breaks the one-`<name>`-per-stack
  ADR-0020 coupling and makes zone additions a state-shape change within
  one stack.

### 4. Which state-key shape segment for zones?

Route53 is global, but the ADR-0020 key embeds `<region>` (the Terragrunt
folder of the deploying stack) — precedent says module path and state
segment are independent (INV-0004).

- **a. `dns` (recommended):** `<account_name>/<region>/dns/<name>/…` —
  generic segment, room for non-Route53 DNS producers later; `<region>` is
  simply where the lookup stack lives (same convention every global-ish
  producer would use).
- b. `route53` — names the service like `rds/…` does, at the cost of
  coupling the segment to the implementation.
- c. `dns/zone` — two-level like `rds/<flavor>`, leaving room for
  `dns/record` etc.; deeper than any current single-resource shape needs.

### 5. What is the zone output contract?

- **a. Contract = `zone_id` + `zone_arn`; additive facts = `zone_name`,
  `name_servers`, `private_zone` (recommended).** Contract-first per
  INV-0004 F1: the external-dns policy needs the ARN (resource scoping) and
  the id (zone filters / TXT registry args); everything else is additive
  and renameable pre-1.0.
- b. Contract additionally includes `name_servers` (delegation wiring for
  parent-zone NS records) — plausible future consumer, but no consumer
  needs it yet; additive keeps it available without contract-locking it.

### 6. How does Object Lock enter the S3 family?

- **a. New `s3/evidence-bucket` purpose module + purpose-only core input
  (recommended).** Core gains `object_lock` (object: enabled + mode +
  days/years, default disabled — a no-op for every existing bucket) with
  the versioning precondition; the purpose module pins versioning on,
  Object Lock on, **COMPLIANCE** default retention (the "admins cannot
  shorten" requirement — GOVERNANCE stays selectable for lower-stakes
  tiers), F2 baseline otherwise. Honors DESIGN-0019's "new needs = new
  purpose modules" ruling.
- b. Same core input but exposed as knobs on `s3/bucket` instead of a new
  module — contradicts the recorded DESIGN-0019 Non-Goals ruling.
- c. Standalone module outside the family (own `aws_s3_bucket`) — forfeits
  the shared F2 baseline and the family's test/enforcement machinery.

### 7. How do the baseline suite and outputs treat Object Lock?

- **a. Documented variant suite + separate output (recommended).** The
  evidence bucket's `security_baseline.tftest.hcl` is a documented variant
  (the access-logs F3-variant precedent: versioning `Enabled`, otherwise
  the full F2 posture), excluded from the byte-identical diff loop; lock
  facts surface through a **new, evidence-module-only `object_lock`
  output** (mode/days derived from the config resource) — the shared
  `security_baseline` object shape stays untouched, so nothing ripples
  into the other modules' suites.
- b. Grow `security_baseline` with lock fields (disabled-valued for the
  other modules) and update the canonical suite + diff loop — one shared
  shape everywhere, at the cost of touching every family suite now and on
  every future lock-surface change.

### 8. What lifecycle surface does the bucket module expose?

- **a. Extend the core type with transitions, expose the full typed list,
  re-export `lifecycle_rule_ids` (recommended).** Core's
  `extra_lifecycle_rules` gains optional
  `transitions = list(object({ days, storage_class }))` and
  `noncurrent_version_transitions` (+ close the existing coverage gap on
  the untested attributes); `s3/bucket` passes a same-typed
  `lifecycle_rules` variable straight through and re-exports
  `lifecycle_rule_ids` as the plan-suite window. Tiering (the stated
  Thanos/Loki/ClickHouse need) works day one; access-logs-bucket is
  untouched.
- b. Expose the type as-is (expiration-only) now, add transitions in a
  later pass — smaller diff, but the exposure exists to serve tiering,
  which it wouldn't.

### 9. What shape is the externally-managed secret mode?

- **a. A `value_mode` discriminator on the existing module (recommended):**
  `value_mode ∈ {"generated", "external"}`, default `"generated"` (zero
  change for existing consumers). External gates the ephemeral + version
  resources to zero (probe-validated, F6), keeps shell/policy/KMS/naming/
  key-shape identical, adds a precondition failing generation-only knobs
  set under external, and the two generation-echo outputs
  (`secret_string_version`, `username`) go **faithfully null** (the
  `kms_key_arn` precedent). Enum (not bool) so the deferred BYO-ephemeral
  leg (DESIGN-0020 Follow-up 4) can land later as a third value without
  another surface change.
- b. A separate `secretsmanager/external-secret` sibling module — cleaner
  per-module story, but duplicates the shell/policy/KMS/naming surface and
  splits the `secrets` state-shape producers across two modules.
- c. A `generate_value` bool — smallest surface, but a third mode later
  forces a breaking rename.

### 10. Does external mode seed a placeholder version?

- **a. No version resource at all in v1 (recommended).** The shell exists;
  `GetSecretValue` fails until the provisioner writes the value — an
  ordering contract the consuming stacks own (documented in the README).
  Simplest surface, trivially no-leak, matches the defer-until-concrete-
  need discipline; the ECR-style write-only placeholder (option b) is a
  recorded follow-up if a consumer needs a well-formed shape pre-population.
- b. Optional caller-supplied placeholder template seeded via
  `secret_string_wo` + pinned version 1 (the ECR pattern) — consumers can
  always read *something*; adds a value-shaped input to a mode whose point
  is "never a value" (placeholder only, but the review surface widens).

### 11. What shape is the access-entries surface?

- **a. Additive generic map alongside the SSO pair (recommended):**
  `access_entries = map(object({ principal_arn, type = optional("STANDARD"),
  kubernetes_groups = optional(list), user_name = optional(string),
  policy_associations = optional(list(object({ policy_name,
  access_scope = optional(object({ type = optional("cluster"),
  namespaces = optional(list) })) }))) }))` — direct ARNs (no regex
  resolution), full namespace scoping (which the SSO path lacks), validation
  that non-STANDARD types carry no groups/associations, and
  `bootstrap_cluster_creator_admin_permissions` made explicit while in the
  file. SSO resources keep their addresses: zero test/consumer churn.
- b. Subsume SSO into the generic map (`moved` blocks, SSO becomes sugar or
  is dropped) — one surface, but a breaking variable change and address
  migration for every existing cluster stack, for no hub-side gain.

### 12. What is the private-endpoint posture toggle?

- **a. Expose `endpoint_public_access_cidrs` + an endpoint guard; no
  default flips (recommended).** Private-only already exists mechanically
  (`endpoint_public_access = false`); add the missing
  `public_access_cidrs` pass-through (default `["0.0.0.0/0"]`, the current
  implicit behavior) and a precondition that at least one endpoint is
  enabled. Spoke stacks set `endpoint_public_access = false` explicitly;
  hub stacks can CIDR-fence instead. The IMPL-0001-Q11-vs-DESIGN-0002
  drift stays resolved-by-documentation (defaults unchanged, non-breaking).
- b. A named posture enum (`"public-and-private"` / `"private-only"`)
  replacing the two booleans — reads well, but a breaking surface change
  and the booleans + CIDRs express strictly more states.
- c. Also flip `endpoint_public_access` default to `false` (DESIGN-0002's
  original intent) — the secure default, but breaking for every existing
  consumer and test; if wanted, it's a major-bump decision to record in the
  DESIGN, not a silent flip.

### 13. What shape is the workload class input?

- **a. Enum class + baked per-class rules + nullable gVisor override
  (recommended).** `workload_class` string, default `"secure"`, validated
  against `{core, observability, temporal, secure}` (the hub §2 set; new
  classes are deliberate module changes). Behavior baked per the hub rule:
  label `workload-class=<class>` always; taint `<class>:NO_SCHEDULE` for
  every class **except `core`**; gVisor (install + `runtime=gvisor` label +
  kubelet fragments) enabled iff `coalesce(var.gvisor_enabled,
  workload_class == "secure")` — `gvisor_enabled` is a nullable bool
  override for the odd case (e.g. a sandboxed observability pool). Threads
  all five F8 sites; default preserves every existing consumer and test.
- b. Free-form class string + fully orthogonal `taint_enabled` /
  `gvisor_enabled` toggles — maximum flexibility, but the platform opinion
  (which classes exist, which are tainted) leaks to every caller and
  typos become silent new classes.
- c. Enum class only, no gVisor override — smallest surface; the first
  class that wants non-default sandboxing forces a surface change.

## References

- Hub/spoke platform design + its RFC-0001 ("harness-removal") — **external
  to this repo** (OQ 1); requirement statements taken from the operator
  request, 2026-08-13.
- INV-0004 — VPC module downstream remote-state contract (the lookup-module
  pattern: contract-first, ship-read-only-first, path vs segment)
- DESIGN-0019 / IMPL-0018 / INV-0009 — the S3 family architecture, the
  purpose-module ruling (Non-Goals), the baseline diff-guard, F6 probe
  discipline
- DESIGN-0020 / IMPL-0019 / INV-0010 — the secret producer, the deferral
  list (BYO-value), count-gated-ephemeral probe results, the conftest
  credential gate
- DESIGN-0001 / IMPL-0002, ADR-0005..0012 — the secure node posture (gVisor,
  taints, AL2023, IMDS, ON_DEMAND, SSM, RuntimeClass out-of-band)
- DESIGN-0002 / IMPL-0001 (Q3, Q7, Q8, Q11), DESIGN-0015 Non-Goals — the
  cluster access surface, endpoint-default drift, external-dns heritage
- DESIGN-0004 / IMPL-0004, ADR-0002 — pod-identity-access (the external-dns
  consumer path, `inline_policies` JSON channel)
- ADR-0020 — remote-state key contract (the shape table the `dns` segment
  joins)
- Provider schema probe: `terraform providers schema -json` against aws
  6.58.0 (`~> 6.2`), 2026-08-13 — F2 table
