---
id: INV-0011
title: "Platform hub module gaps across network, s3, secretsmanager, and eks"
status: Concluded
author: Donald Gifford
created: 2026-08-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0011: Platform hub module gaps across network, s3, secretsmanager, and eks

**Status:** Concluded
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
    - [Hub topology distillation from the shared ADR](#hub-topology-distillation-from-the-shared-adr)
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

#### Hub topology distillation from the shared ADR

The operator shared the platform's topology ADR ("Kubernetes Runtime and
Cluster Topology", Proposed, 2026-07-25) on 2026-08-14. The
module-relevant facts, distilled here per the OQ 1 resolution (the temp
copy under `modules/eks/` is reference-only and gets deleted; this
section is the in-repo record):

- **Topology:** a **management cluster (hub)** — EKS, hosting GitOps and
  core platform services, applications never run there — with
  **environment clusters (spokes)** for dev / stage / prod, **each in its
  own AWS account**, gated by a promotion workflow. A **sandbox** lives in
  a separate AWS organization (own identity, no standing trust) hosting
  isolated EKS and Talos burner environments, outside the promotion flow;
  the hub-to-sandbox management channel boundary is explicitly TBD.
- **Module consequences:** the hub is critical infrastructure — "HA and
  break-glass access are required" — which is the direct requirement
  behind the break-glass access entry (OQ 11) and the endpoint-fence work
  (OQ 12). Spokes living in their own accounts means the hub principals
  (argocd-deployer, provisioner) reach spoke clusters **cross-account** —
  exactly why the generic `access_entries` map takes direct principal
  ARNs instead of the SSO path's in-account regex resolution. Talos and
  the sandbox organization sit outside this fleet's Terraform scope (the
  EKS modules serve hub + spokes; burner environments are not consumers).
- **Still missing (lives in the parent "Internal Security Platform RFC",
  not the ADR):** the §2 workload groups (core / observability /
  temporal / secure) behind OQ 13, the hub principals enumeration, and
  the Loki/audit evidence-retention requirement ("harness-removal")
  behind the S3 evidence bucket. Thanos appears in the ADR only as a
  follow-up pointer ("long-term metrics retention (Thanos)") — consistent
  with the S3 tiering ask. Those RFC sections should be shared for
  distillation when the S3 and node-class DESIGNs are written; until
  then, the requirement rows stand as given in this INV.

**Second batch (2026-08-14):** five more platform docs shared —
Management Cluster Baseline ADR, Kubernetes Platform RFC (their
RFC-0002), Cluster Provisioning ADR, Central Monitoring Stack ADR, and
the Talos modules DESIGN (a separate future repo; out of scope here
beyond confirming sandbox/Talos never consumes this fleet). What they
settle:

- **The ArgoCD-to-spoke auth path IS the access-entries consumer:** the
  hub registers spokes via Secrets Manager + External Secrets Operator
  (connection metadata only — no tokens), and "the ArgoCD controllers
  authenticate to spokes via IAM and EKS access entries." OQ 11's
  generic map has its first concrete cross-account principal. The
  registration secret itself (value written by the provisioning tool,
  never by Terraform) plus ESO-read git-credential/OIDC secrets confirm
  the OQ 9 external-mode + `read_principals` shape ("secrets flow one
  way, from Secrets Manager into the cluster").
- **S3 backing confirmed:** "Object storage (S3) backs Thanos and Loki;
  block storage serves only hot paths. Retention and lifecycle policies
  are set per store" — the OQ 8 lifecycle/tiering exposure and the
  evidence bucket serve the Thanos + Loki stores; ClickHouse rides
  block storage (S3 only for backups, if ever).
- **Split-horizon DNS confirmed:** the hub baseline runs external-dns
  "serving both our internal DNS and external DNS" — supporting OQ 3's
  one-zone-per-stack with public/internal folder names.
- **~~THE TRAJECTORY CAVEAT~~ (SUPERSEDED — see batch 3):** the Cluster
  Provisioning ADR's Go-reconciler direction ("Terraform/Terragrunt is
  removed from the cluster path") was shared in error — the operator
  flagged it as no longer current, and batch 3 carries the replacement
  decision.
- **Still missing after batch 2:** the parent Internal Security
  Platform RFC (their RFC-0001 — the "harness-removal" evidence
  requirement text; the sandbox hosts "security testing, harness
  evaluation, and red-team exercises," which is the closest shared-doc
  context) and the §2 workload-group definitions. *(Batch 4 closed the
  §2 half — the workload-group definitions arrived with DESIGN-0001;
  only the RFC-0001 evidence text remains outstanding, wanted by the
  S3 evidence-bucket DESIGN.)*

**Third batch (2026-08-14):** the platform's ADR-0011 ("Use Terraform
with ArgoCD Bootstrap for Cluster Provisioning", 2026-08-13) and the
platform-side IMPL-0001 ("Terraform Module Work for the Management
Cluster Substrate") — the current position, superseding the
Go-reconciler ADR from batch 2:

- **This repo's eks modules ARE the cluster path, long-term.** Clusters
  are "Terraform stacks composed from the eks/\* modules"
  (`eks/cluster` + `eks/managed-node-group`(s) + `eks/addons`,
  Terragrunt-composed per environment account, VPC via `vpc-lookup`
  remote state). The stack's boundary is the registration secret
  (written to Secrets Manager in `sse-mgmt` by the cluster stack — the
  live repo, never substrate module Terraform); ESO/ArgoCD own
  everything past it. Direct quote on what that means here: "The
  eks/\* modules become load-bearing platform components, not just
  conveniences — their change bar (zero-diff replans, plan-test
  invariants) is now platform policy." The EKS DESIGN is therefore a
  full long-term surface, not a day-0 reference spec. A Temporal-based
  engine remains a parked future direction (its own ADR if fleet churn
  ever demands it; leading candidate is Talos machine lifecycle, not
  the EKS path).
- **The platform IMPL-0001 is the cross-repo rollup of exactly this
  INV's work** (its Phase 1 = OQs 6–13's module changes; docz IDs are
  per-repo, and each item gets a repo-local DESIGN/IMPL here that the
  rollup links). It also adds adjacent work this INV did not cover,
  queued behind the hub items: **`iam/deploy-role`** (codifies the
  deploy role every ADR-0020 `assume_role` read references, state key
  `<account>/<region>/iam/<role>`), **`iam/cross-account-role`** (the
  `sse-platform-access` pattern), both Phase 2 (spoke substrate); and
  parked Phase 3 triggers (`ecr/org-registry` multi-org on sandbox
  build, `elasticache/redis` on the Langfuse queue decision, `org/*`
  home decision). Network modules are explicitly out of scope
  (DESIGN-0001 assumes externally managed network — consistent with
  `vpc-lookup` as the consumption path).
- **Three conflicts between the platform rollup and this INV's
  resolutions — all reconciled 2026-08-14, this repo's resolutions
  stand; the rollup doc needs the corresponding amendments on the
  platform side:** (1) the rollup pins `workload_class` "**default
  remains `secure`**" with a zero-diff replan success criterion, vs
  the OQ 13 resolution (2026-08-14, confirmed) flipping the default to
  `core` — core default stands (zero live consumers); the rollup's
  "today's secure posture exactly" success criterion must be amended.
  (2) The rollup puts Object Lock on `s3/bucket` directly, vs OQ 6a's
  new `s3/evidence-bucket` purpose module (this repo's DESIGN-0019
  "new needs = new purpose modules, not new knobs" ruling) — the
  purpose module stands; the core grows the capability, the purpose
  module exposes it. (3) The rollup's Phase 2 module is **`dns/zone`**
  — a create module ("platform zone + per-account delegation; no
  record resources"), vs OQ 3/4's read-only `dns/zone-lookup` first;
  the operator re-confirmed **lookup first** ("for dns we need the dns
  lookup first"), so `dns/zone-lookup` ships as the contract producer
  and the create-mode `dns/zone` follows as its Phase-2 sibling in the
  same `dns/` directory.
- **The "§2" source is identified:** the platform's DESIGN-0001
  ("Management Cluster and Multi-Cluster Substrate" — §2 node groups
  incl. the reserved `temporal` group, §4 IAM, §6 module review) is
  the doc the rollup implements — shared and distilled in batch 4
  below.

**Fourth batch (2026-08-14):** the platform's DESIGN-0001 itself
("Management Cluster and Multi-Cluster Substrate", Draft 2026-08-13) —
the §2/§4/§6 source the rollup implements, closing batch 3's gap:

- **Account layout (§1):** `sse-mgmt` hub plus `sse-prd`/`sse-stg`/
  `sse-dev` spokes in the primary org; `sse-sandbox` in a **separate
  org** (no IAM trust, build deferred). The account boundary is the
  environment boundary.
- **§2 node groups (the original request's "§2"):** the hub runs three
  purpose-built groups, each an `eks/managed-node-group`
  instantiation — `core` (untainted, the default landing zone; ArgoCD,
  Kargo, ESO, ALB controller, Headlamp, platform operators),
  `observability` (label + `NO_SCHEDULE` taint; kube-prometheus/
  Thanos, Alertmanager, Loki, Grafana, ClickHouse, Langfuse, hub
  Alloy), and `temporal` (reserved, label + taint). **No `secure`
  group on the hub** — the OQ 13 enum
  `{core, observability, temporal, secure}` covers the hub's three
  plus the currently hardwired class. **Split seam the EKS DESIGN must
  note:** DESIGN-0001 reserves splitting `observability` into
  `monitoring` + `observability` as "a label change in the baseline
  charts, not a redesign" — under the closed-enum resolution that
  split needs a one-line enum addition in this repo first, so the
  DESIGN should record the enum as deliberately cheap to extend
  (additive value + baked rule, no structural change). **Cut line
  resolved 2026-08-14:** the o11y stack always spins up first and
  stays together — **Loki lives with kube-prometheus/Thanos,
  Alertmanager, Grafana, and Alloy on `observability`**, and the
  split, when it fires, peels ClickHouse + Langfuse off to a new
  class. This contradicts DESIGN-0001's seam on both counts (its
  metrics-vs-logs+analytics cut puts Loki with ClickHouse/Langfuse,
  and its `monitoring` name would relabel the entire o11y stack at
  split time while analytics kept the `observability` label —
  inverting the churn); the platform-side sentence needs amending.
  The fifth pre-baked enum value is therefore the **analytics** class
  (recommended name `analytics`, finalized at EKS DESIGN review), so
  the split is a live-repo + chart change with no module release in
  the path — the same reserve-ahead-of-need move as `temporal`.
- **§4 IAM (feeds the access-entries and IAM-pair DESIGNs):** concrete
  principals for the generic `access_entries` map — each spoke binds
  the hub argocd-deployer's assumed `sse-platform-access` role to a
  deploy RBAC group and break-glass SSO to admin; human access
  everywhere is SSO permission sets → access entries (no static
  kubeconfigs); cluster stacks apply via the per-account
  `iam/deploy-role` path, never hub-resident credentials.
- **Endpoint posture confirmed:** the Assumptions state hub → spoke
  connectivity as "hub → spoke **private** EKS API endpoints" — spokes
  run private-only (OQ 12's motivating case) while the hub keeps
  private+public with the fence.
- **Reserved state keys:** DESIGN-0001 names
  `<account>/<region>/iam/<role>` and `<account>/<region>/dns/<zone>`
  — the platform side of the ADR-0020 contract for the IAM pair and
  the `dns/` family; `zone-lookup` publishes/asserts the same
  `dns/<zone>` shape (OQ 4 confirmed from the producer side).
- **§6 review deltas:** all three batch-3 conflicts trace to this
  doc's wording (secure default, Object Lock on `s3/bucket`,
  `dns/zone` create) — the platform-side amendments belong here as
  well as in the rollup. `ecr/org-registry` multi-org is phrased
  stronger here ("the policy surface should grow now rather than be
  retrofitted") but stays trigger-gated per the rollup.
- **GAP flagged for the operator:** §2's AWS-side dependency list
  includes **ACM certs** (the Gateway-class hostnames), but no `acm`
  module exists in this fleet and neither §6's review table nor the
  rollup's work list carries a row for it — either the live repo uses
  raw resources for certs or a module is missing from both platform
  docs. **Resolved 2026-08-14 — parked:** the existing certs live
  outside Terraform today, and a lookup + create/adopt pair would only
  bring them under management while nothing in the fleet consumes the
  ARNs (the consumer is the Gateway listener config the LBC applies —
  chart-side) — "terraform for terraform's sake" per the operator.
  Live-repo concern until a real Terraform consumer appears; any
  future module is an `acm/certificate` create/adopt shape (whose
  DNS-validation records are a noted carve-out to the
  no-record-resources rule — external-dns never owns validation
  plumbing), not a lookup.
- **NEW module surfaced by the ACM discussion (operator-proposed,
  2026-08-14): the Gateway frontend security-group module.** The
  rule-ownership seam is resolved **frontend-only Terraform**: the
  LBC keeps the backend SG and node-SG rule management (closer to
  the source that defines target ports and health checks — the k8s
  repo), matching current practice where a new Gateway is handed
  frontend SG IDs only. The module owns the per-Gateway-class
  ingress-allowlist SGs (`external`: operator UIs — argocd CLI/API,
  Kargo, webhook sources like GitHub; `internal`: spoke telemetry
  ingest), with typed rules accepting CIDRs **and prefix-list IDs**.
  Unlike the OQ 12 EKS endpoint fence, SG rules reference prefix
  lists **natively and live** (`prefix_list_id` on
  `aws_vpc_security_group_ingress_rule`) — list updates propagate
  with zero Terraform applies, exactly the lifecycle OQ 12 wished
  for and could not have. Needs only `vpc_id` from `vpc-lookup` (no
  eks state read); composes cleanly against the node SG's
  established granular-rules shape (`eks/cluster/security_group.tf`
  — no inline rules) without ever touching it, and allowlist churn
  never replans cluster or node-group stacks. Recorded posture: the
  operator's default is the **hairpin model** (company-network
  traffic egresses and re-enters via the external ALB rather than
  multi-homing routes), with split-horizon internal DNS remaining an
  open per-service option — the module surface is identical either
  way, so it is not a one-way door. DESIGN sizing note: prefix-list
  entries count against the rules-per-SG quota by the list's
  `max_entries`.
- **Also confirmed:** the hub-shaped test fixture expectation (tagged
  VPC → `vpc-lookup` → eks stacks — exactly the `reference-vpc` +
  rollup Phase-2 criterion); the registration-secret schema
  (`{name, endpoint, ca_data, labels: {environment, class}, auth:
  {role_arn}}`) as the stable contract no module here ever writes;
  substrate SM shells restricted to externally-sourced values — git
  credentials and Okta OIDC clients are the SM external mode's
  concrete first consumers; and the S3 consumers by name (Thanos /
  Loki / ClickHouse tiering for `extra_lifecycle_rules`, Loki/audit
  retention for the evidence bucket, the existing access-logs sink).

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
the split) in this order: `dns/zone-lookup` first (smallest, pure
producer, no existing-module risk, unblocks the external-dns pod-identity
worked example; lookup-first re-confirmed 2026-08-14 — see F1 batch 3),
then the S3 pair (one family DESIGN: evidence bucket + lifecycle exposure
— both touch the core, ride one core change), the Secrets Manager external
mode (small, pattern-established), and the two EKS changes (access
surface + endpoint posture; workload class). Each DESIGN cites the hub
doc per the OQ 1 convention.

**Fan-out delivered 2026-08-27:** the four hub-day-0 DESIGNs exist —
**DESIGN-0021** (dns/zone-lookup), **DESIGN-0022** (S3 evidence bucket +
lifecycle tiering exposure), **DESIGN-0023** (Secrets Manager externally
managed mode), **DESIGN-0024** (EKS hub posture: access entries +
endpoint fence + workload classes). All Draft; each encodes this INV's
resolutions as decided and carries its own numbered Open Questions
(lettered options, a = recommendation) for operator review.

Queued behind the hub-day-0 four (from the platform rollup's Phase 2 —
spoke substrate; each fires its own DESIGN here when work starts, per the
rollup's cross-repo convention): **`dns/zone`** (create mode — platform
zone + per-account delegation, no record resources; sibling to
`zone-lookup`), **`iam/deploy-role`** (codifies the deploy role every
ADR-0020 `assume_role` read already references),
**`iam/cross-account-role`** (the `sse-platform-access` pattern), and the
**Gateway frontend security-group module** (operator-proposed, F1 batch 4
— frontend-only ingress-allowlist SGs per Gateway class with native
prefix-list rules; backend stays with the LBC). Parked with triggers
(rollup Phase 3 + F1 batch 4): `ecr/org-registry` multi-org (sandbox
build), `elasticache/redis` (Langfuse queue decision), `org/*` (home
decision), and `acm/certificate` (parked until a Terraform consumer of
cert ARNs exists — today the ARN consumer is chart-side). The IAM pair
wants the platform's DESIGN-0001 §4 shared before its DESIGN is written.

**EKS delivery (2026-08-30, IMPL-0020):** the hub posture work is
built — F7 and F8 are both closed. `managed-node-group` carries the
five-class `workload_class` enum (`core` default; the five hardwired
sites threaded) plus the `gvisor_enabled` override, with the fleet's
first rendered-user-data assertions (plan suite 6 → 22 runs).
`eks/cluster` carries the additive endpoint fence, its three guards,
the explicit bootstrap posture with the stable-creator contract, and
the additive `sso_principal_arn` output (4 → 12 runs, every
pre-existing run unchanged — the zero-diff bar held). The new
**`eks/access-entries`** module is the fourth eks-state consumer
(12 runs). Two things found in the building that the DESIGN did not
anticipate: gating the gVisor MIME part as written would have silently
dropped the ECR pull-through mirror on every non-gVisor class (the two
now gate independently), and **EKS is Pro-only in LocalStack** —
probed directly on token-free Community 4.4, which answers
`ListClusters` with a license error — so IMPL-0020 OQ 4's
Community-`plan_smoke` fallback is moot and the new module's apply
suite carries the same Pro requirement its three siblings already do.
The live apply runs across the three modules remain **pending an
operator Pro container**; all three plan gates are green.

**Queue revision (2026-08-28, operator-reviewed):** re-scoped after the
post-merge gap review of platform DESIGN-0001 §5 coverage against the
merged DESIGN-0021..0024 set:

- The IAM pair condenses into **one generic `iam/role` module** —
  `iam/deploy-role` and `iam/cross-account-role` have identical resource
  surfaces (role + trust policy + managed attachments + inline
  policies); the inputs define which pattern an instance is. The deploy
  role already exists outside Terraform in the other accounts, so the
  module's brownfield job is adoption via `import` blocks, not
  greenfield creation.
- The Gateway frontend security-group module generalizes into
  **`network/security-group`** — a generic standalone ingress-allowlist
  SG producer with standard outputs (cidr / prefix-list / referenced-SG
  typed rules, granular rules only, never inline). The frontend-only
  scope guardrail stands: resource-owning modules keep their own SGs,
  and the LBC keeps backend + node-SG rules.
- **`dns/zone` (create mode) is deprioritized** — the platform zone is
  provided externally, so only the lookup (DESIGN-0021) is near-term;
  the create sibling waits for a real delegation need.

Near-term queue is therefore three items: the `dns/zone-lookup` IMPL
(already designed), the `iam/role` DESIGN, and the
`network/security-group` DESIGN.

**Sequencing note (2026-08-28) — hub buildout can start in parallel:**
none of the three queue items sits on the mgmt-cluster critical path;
manually-built substrate adopts into the modules later. In order of how
cleanly "later" works:

- **Trivially deferrable — nothing to import, ever:** `dns/zone-lookup`
  is zero-resource, so adopting it later is just adding a read stack.
  Better: the external-dns / cert-manager pod-identity stacks can
  hardcode the provided zone's ARN in their `inline_policies` JSON
  today, and swapping to the remote-state read later produces a
  zero-diff plan (same ARN, same rendered policy). No migration at all.
- **Cleanly importable later — build manually now, adopt with `import`
  blocks:** IAM roles: the existing deploy + cross-account roles import
  cleanly into the future `iam/role` (role, managed attachments, and
  inline policies all import individually; trust-policy diffs converge
  in place, zero downtime — IAM is metadata). Frontend SGs: the SG and
  each rule import individually into `network/security-group`, and rule
  descriptions update in place; worst case is the module replacing a
  rule to match its conventions (a brief window on a live ALB SG), so
  the play is import-and-match-reality first, converge conventions
  second. SM shells: create the git-cred/OIDC secrets manually and
  import just the shell once external mode (DESIGN-0023) lands —
  external mode manages no version resource, so the import is exactly
  the shell and the operator-written value is untouched.

Two real sequencing constraints exist, both from the
designed-but-unbuilt work rather than the queue:

1. **Node-group workload classes (DESIGN-0024 part 3) gate hub day-0 —
   not deferrable.** A mgmt cluster built on today's
   `managed-node-group` gets every node hardwired
   `workload-class=secure:NO_SCHEDULE` + gVisor; the core baseline
   (ArgoCD, ESO, ALB controller) tolerates nothing and expects
   untainted `core` nodes — nothing schedules. `additional_labels`
   cannot remove the hardwired taint, and tolerating it chart-side
   puts the control plane under gVisor, exactly the posture the class
   split exists to avoid. Recovery later is a launch-template bump plus
   rolling node replacement (survivable on a young hub), but the clean
   path is sequencing the DESIGN-0024 node-group phases before the hub
   cluster stack applies. The cluster-side changes gate nothing (fence
   defaults are today's behavior; the access-entries stack trails;
   bootstrap admin covers access meanwhile).
2. **The evidence bucket cannot be retrofitted.** `object_lock_enabled`
   is create-time — a Loki bucket created now can never become the
   evidence bucket (that is a new bucket + data copy). Either land the
   S3 core + evidence work (DESIGN-0022) before the audit stream
   matters, or knowingly accept a cutover window. The Thanos /
   ClickHouse buckets are the opposite: create with `s3/bucket` at HEAD
   today and add tiering later as a pure additive `lifecycle_rules`
   change.

Fastest buildout order: implement the node-group classes first (they do
not depend on the cluster-side DESIGN-0024 phases), start the hub
substrate + cluster stack against that, and let everything else — the
dns lookup, the IAM and SG modules, external SM mode, even the evidence
bucket if the cutover is accepted — land behind it and adopt what was
built by hand. This is the fleet's own doctrine: brownfield import-first
was baked into the create-or-adopt thinking from INV-0004, so the
modules are designed to receive what the buildout creates manually.

## Open Questions

> **All resolved 2026-08-14: 2a, 4a, 5a, 6a, 7a, 8a, 9a, 10a, 11a; 1, 3,
> 12, and 13 resolved with modifications.**
>
> - **OQ 1 (Other — distill, don't just cite):** worth doing. The
>   hub/spoke model's module-relevant parts get pulled from the external
>   hub docs into this repo rather than cited blind — landing first as
>   the EKS DESIGN's Context section, promoted to a standalone reference
>   doc only if it outgrows that. **Progress:** the topology ADR was
>   shared and distilled into F1 on 2026-08-14 (batch 2), the
>   cluster-path correction + rollup on 2026-08-14 (batch 3), and the
>   platform DESIGN-0001 with the §2 workload groups and §4 IAM on
>   2026-08-14 (batch 4) — only the platform RFC-0001
>   evidence-retention text remains outstanding (S3 evidence-bucket
>   DESIGN input).
> - **OQ 3 (a, plus the path):** one zone per instance, AND the module
>   lives at **`modules/dns/zone-lookup`** — a new `dns/` service
>   directory mirroring `network/vpc-lookup`'s naming, leaving sibling
>   room for a future create-mode `dns/zone` the way `network/` leaves
>   room for `network/vpc`. Path and state segment align (`dns/`).
>   **Re-confirmed 2026-08-14** against the platform rollup's Phase-2
>   `dns/zone` create module: lookup ships first; `dns/zone` follows
>   as the sibling (see F1 batch 3, conflict 3).
> - **OQ 13 (a, modified — core default, CONFIRMED 2026-08-14):** enum
>   `{core, observability, temporal, secure}` + baked per-class rules +
>   nullable gVisor override as designed, with **`workload_class`
>   defaulting to `"core"`** — the operator confirmed nothing built from
>   the eks modules exists that can't be rebuilt, so the lower-entry
>   default lands now while there are zero live consumers (no migration
>   burden; the DESIGN still records it as the default-behavior change
>   vs the previously hardwired secure). The plan suite must test BOTH
>   the core-default run AND an explicit `secure` run — secure is the
>   highest-stakes class and "needs to be dialed." **Amended
>   2026-08-14 (F1 batch 4 split seam):** the enum gains a fifth
>   pre-baked class for the future ClickHouse/Langfuse split —
>   `{core, observability, analytics, temporal, secure}` — with Loki
>   staying on `observability` (the o11y stack spins up first and
>   stays together); the `analytics` name is the recommendation —
>   **confirmed 2026-08-27** at DESIGN-0024 review (its OQ 1a).
> - **OQ 11 (a, amended 2026-08-27 at DESIGN-0024 review):** the
>   generic map's shape stands, but it lands in a **new
>   `eks/access-entries` module** (an eks-state consumer like the
>   other three) rather than inside `eks/cluster` — operator
>   direction: access-entry churn must never replan the cluster
>   stack. The SSO pair stays in `eks/cluster` untouched; the
>   cluster gains one additive `sso_principal_arn` output feeding
>   the cross-stack collision guard.
> - **OQ 12 (Other — operator shape):** the `endpoint_public_access =
>   true` default and its implicit `["0.0.0.0/0"]` fence are the
>   unbroken contract. Additively: `endpoint_public_access_cidrs`
>   (literal CIDRs, default `[]`) and
>   `endpoint_public_access_prefix_list_ids` (expanded to CIDRs via
>   `data.aws_ec2_managed_prefix_list` at plan time); the effective
>   fence is the union of both, and an empty union resolves to
>   `["0.0.0.0/0"]` — so nothing set means exactly today's behavior.
>   README carries a warning callout: expansion is **plan-time only**
>   (prefix-list edits land on the next apply of the cluster stack, not
>   live like an SG prefix-list reference) and the union counts against
>   the EKS 40-CIDR public-endpoint limit. Guards: at least one endpoint
>   enabled; fence inputs set while the public endpoint is off fail the
>   plan. **The conditional ignore-changes idea is recorded as
>   infeasible as asked:** Terraform `lifecycle` arguments are static
>   (they cannot reference variables), so the module cannot ignore
>   outside-Terraform fence changes only when prefix lists are in use —
>   and an unconditional ignore would make the literal CIDR variable
>   inert after creation. Live prefix-list sync is therefore a recorded
>   follow-up (an out-of-band syncer such as EventBridge-on-prefix-list
>   -change plus a module-wide ignored-fence posture decision), not a v1
>   knob.

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
