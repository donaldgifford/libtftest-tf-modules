# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Repository purpose

A monorepo of AWS Terraform modules intended to be tested with
[libtftest](https://github.com/donaldgifford/libtftest) (LocalStack-backed Go
integration tests). Modules are organized by service under `modules/<service>/`.
Tracked in git. As of this writing:

- **`modules/eks/`** — `cluster` (IMPL-0001), `managed-node-group` (IMPL-0002),
  `addons` (IMPL-0003), `pod-identity-access` (IMPL-0004). All four implemented.
  **`pod-identity-access` hardened by DESIGN-0027 Part B / IMPL-0024,
  shipped as `v0.24.0`** (PR #114 merged 2026-09-11 — the four
  policy-channel validations, 5 → 9 plan runs). Its
  **Mode B (`create_role = false`) accepts and IGNORES the four Mode A
  policy inputs** — deliberate, regression-tested in
  `mode_b.tftest.hcl`, and documented on every affected variable +
  the README after DESIGN-0027 Part C proposed rejecting the
  combination and was **withdrawn**: Terragrunt injects a uniform
  input set into every module regardless of use (IMPL-0015 Q6a), so
  failing on an unused input would break the fleet's normal calling
  pattern. **Reusable rule: "this input is silently ignored" is a
  documentation defect by default, and a validation defect only when
  nothing yet depends on the tolerance — look for the regression test
  before assuming the silence was an accident.**
  **The Part B backport is possibly plan-breaking** — four shapes that
  planned green since `v0.21.0` now fail (a malformed ARN in either
  channel, non-JSON `inline_policies`, `permissions_boundary = ""`),
  and because the two channel regexes partition on the account field,
  **an ARN in the wrong channel is now an error** where before both
  channels emitted an identical attachment and either worked. Moving
  one between channels is **not address-neutral**: the attachment is
  keyed by channel, so it plans as destroy + create — a real brief
  detach window, not something to fold into an unrelated apply. Both
  the README's upgrade section and the release notes say so.
  **Hub posture shipped as `v0.21.0` (IMPL-0020 / DESIGN-0024, PR #106
  merged 2026-09-01)** — the hub-unblock milestone tag the management-cluster
  buildout pins; one minor tag carries all three modules (OQ 1a's three-PR
  cadence collapsed to one branch, recorded in the IMPL). These modules are
  now load-bearing platform components per the platform's ADR-0011, so their
  change bar (zero-diff replans, plan-test invariants) is platform policy.
  Phase 1 landed on `managed-node-group`: the five hardwired "secure" sites
  (INV-0011 F8) are parameterized into a closed five-value `workload_class`
  enum — `{core, observability, analytics, temporal, secure}`, the platform
  class taxonomy (platform DESIGN-0001 §2). **The default is now `core`, a
  deliberate default-behavior change** (INV-0011 OQ 13, taken while the
  module had zero live consumers): the class label is always emitted, and
  the `workload-class=<class>:NO_SCHEDULE` taint fires for every class
  *except* `core` — core is the untainted landing zone the platform baseline
  (ArgoCD, ESO, ALB controller) needs, since those tolerate nothing. A
  default invocation is therefore NOT the old secure posture; the explicit
  `secure` run in `tests/workload_class.tftest.hcl` is the regression that
  keeps that posture pinned. Threaded sites: `locals.runtime_labels`,
  `main.tf`'s `dynamic "taint"`, the user-data template's kubelet
  `--node-labels` / `--register-with-taints` fragments (note the deliberate
  spelling split — kubelet wants `NoSchedule`, the EKS API wants
  `NO_SCHEDULE`), and the class-derived `node_labels` / `node_taints`
  outputs. Phase 2 completed the parameterization: `gvisor_enabled` (nullable
  bool, `null` = the class rule) drives
  `local.gvisor_effective = coalesce(var.gvisor_enabled, workload_class ==
  "secure")`, which gates the gVisor install part, the `runtime=gvisor` label,
  and the kubelet label fragment **together** — a node never advertises a
  sandbox it didn't install, nor hides one it did. `local.kubelet_node_labels`
  composes the `--node-labels` flag from the same rules as the resource labels
  so the two label paths cannot drift (caller `additional_labels` still ride
  the EKS API path only — and because that path merges last and wins, the
  three module-managed keys `workload-class` / `runtime` /
  `kubernetes.io/arch` are **reserved**, rejected at validation; without
  that, a caller could set `runtime=gvisor` on a node whose bootstrap never
  installed runsc). **Template gotcha found here:** the ECR
  pull-through mirror config lives *inside* the gVisor shellscript MIME part,
  so gating that whole part on gVisor (as DESIGN-0024 literally reads) would
  silently drop the mirror on every non-gVisor class — the part now renders
  when *either* is on, with the two fragments gated independently, one shared
  `systemctl restart containerd`, and the runsc plugin assertion under the
  gVisor gate. Tests: plan suite 6 → 22 runs, including
  `tests/user_data.tftest.hcl` — the **fleet's first rendered-user-data
  assertions** (base64decode of the launch template's `user_data` +
  `strcontains` per fragment; no test-only output was added, per IMPL-0020
  OQ 2a) covering all five classes, both `gvisor_enabled` override
  directions, and the independent-mirror-gating regression (24 runs after
  the security review below).
  **Phases 1–2 must ship as one release** (IMPL-0020 OQ 1a) — Phase 1 alone
  is a half-threaded intermediate — and that release tag is the hub-unblock
  milestone: the hub cluster cannot be built on a node group whose every node
  is born secure-tainted.
  Phase 3 landed on `cluster`, all additive (every pre-existing plan run
  passes unchanged — the zero-diff bar): the **public-endpoint fence**
  (`endpoint_public_access_cidrs` + `endpoint_public_access_prefix_list_ids`,
  unioned and de-duplicated into `local.public_access_cidrs`; an empty union
  resolves to `["0.0.0.0/0"]`, the value EKS already applied implicitly, so
  clusters setting neither input replan zero-diff — pinned as the suite's
  first run). **Prefix-list expansion is plan-time only** (the EKS API takes
  literal CIDRs; `network/security-group` per DESIGN-0026 is the live
  counterpart) and conditional `ignore_changes` is impossible since
  `lifecycle` args are static. Four plan guards: at-least-one-endpoint,
  fence-on-a-disabled-public-endpoint, the EKS 40-CIDR cap, and
  fence-requested-but-expands-to-nothing (the last from the security review
  below — it is what stops the empty-union → `0.0.0.0/0` fallback from
  firing on a fence the operator *did* ask for). Also
  `bootstrap_cluster_creator_admin_permissions` explicit `true` (was the
  silent provider default) carrying the **stable-creator contract** — the
  entry binds permanently to whatever principal creates the cluster, so
  applies run via Atlantis pod-identity → deploy role, never an ad-hoc SSO
  session whose `AWSReservedSSO_*` suffix rotates — plus the additive
  `sso_principal_arn` output (4 → 12 runs). Phase 4 added
  **`modules/eks/access-entries`** (IMPL-0020), the fourth eks-state consumer
  and the generic principal→cluster surface: `access_entries` map keyed by
  *logical* name with associations flattened to `"<entry>:<assoc>"` keys (so
  re-pointing a principal or adding an association never churns a sibling),
  direct principal ARNs (spokes are separate accounts — the cluster's
  in-account SSO regex can't reach them), eight fail-closed validations, and a
  **cross-stack collision guard** rejecting any entry naming the cluster
  stack's `sso_principal_arn`; that read is `try()`-wrapped so a cluster state
  predating the additive output degrades to no-guard instead of breaking every
  plan (15 runs). It exists as its own stack precisely so access churn never
  plans against the control-plane stack. **The scoping trap it closes:**
  `access_scope.type` defaults to `"cluster"`, so the namespaces-only form
  `access_scope = { namespaces = [...] }` reads as a scoped grant but
  discards the list and grants cluster-wide — rejected at plan, as is the
  inverse (namespace scope, empty list) and any principal named by two
  logical keys (effective access is the union, so a duplicate silently
  widens the tighter entry). The collision guard compares **normalized**
  `<account>/<name>` lowercased, not raw ARNs: `data.aws_iam_roles` returns
  reserved SSO roles path-bearing while access-entry configs use the
  path-stripped spelling, and a raw compare lets that second spelling
  through. **LocalStack finding (IMPL-0020
  Phase 5):** EKS is **Pro-only** — probed directly on token-free Community
  4.4, which answers `eks list-clusters` with "not included in your current
  license plan" and omits `eks` from its health output entirely. So all four
  eks modules' `tests-localstack/` suites need Pro (as their FINDINGS already
  recorded), and IMPL-0020 OQ 4's Community-`plan_smoke` fallback is moot. The
  Phase 5 apply-suite extensions (cluster fence runs, node-group class runs,
  the new module's suite + its two-state fixture) are **authored but not yet
  run live** — each FINDINGS.md carries a pending-re-run note, and the
  operator **deferred the live runs (2026-09-01)**: the release did not
  block on them. **They are the one open follow-up from IMPL-0020**
  (task 5.4, needs a Pro container — `just tf test-localstack
  eks/{managed-node-group,cluster,access-entries}`). DESIGN-0024 reads
  Implemented, IMPL-0020 Completed.
  **Adversarial security review (IMPL-0020, `iac-security`)** closed five
  real holes in the as-built code — two HIGH (the namespaces-only silent
  cluster-wide grant; the emptied-prefix-list fence falling through to
  `0.0.0.0/0`), three MEDIUM (forged `runtime=gvisor` label; the
  path-spelling evasion of the collision guard; duplicate principals) —
  each with a regression run, all detailed above and in IMPL-0020. Two
  findings were **rejected as deliberate**: the `try()` fail-open degrade
  (worst case is an apply-time `ResourceInUseException`, never a grant)
  and `kubernetes_groups` accepting `system:masters` (the module's point).
  The two HIGHs share a shape worth carrying into future modules — **a
  permissive default plus a partially-specified input is a silent
  widening**, so validate the *coherence* of an input object, not just its
  fields, and test a fallback against the resolved value rather than the
  raw inputs. The review also prompted a **live-coverage sweep** of the
  Phase 5 apply suites, which closed three gaps where a green plan-suite
  regression sat over a degenerate live case: the access-entries collision
  run compared two identical strings (its fixture role now carries a
  `path`, so the two real ARN spellings exist); the cluster suite passed
  only literal CIDRs, leaving `data.aws_ec2_managed_prefix_list` and the
  whole expansion path unproven (its fixture now builds a populated **and**
  an empty managed prefix list — which also asks the emulator, uniquely in
  this fleet, whether it serves prefix-list `entries` at all); and the
  node-group suite never enabled the opt-in mirror, so the
  mirror-on/gVisor-off combination the template deviation would have broken
  never reached EC2. **The lesson: a fix is not covered just because a
  regression exists at the tier where the logic lives.**
  A follow-on **design-conformance audit** (DESIGN-0024 read end-to-end
  against the shipped code) found the functional surface complete — every
  variable, output, guard, OQ resolution and Non-Goal accounted for — and
  four gaps entirely outside it: `launch_template.tf` still described every
  node group as "secure" regardless of class (it predates DESIGN-0024 and
  was never swept, which **falsified Phase 1's "grep-verified" success
  criterion** — the grep covered variables/locals/main/outputs.tf only);
  the cluster README documented three fence guards when there are four,
  omitting the one that can fail a previously-succeeding plan; two stale
  README claims (run counts, and an EKS-consumer list missing
  `access-entries` itself); and the reserved `additional_labels` keys were
  prose-undocumented. **The pattern worth carrying: the tested surface
  held, and everything that drifted was what tests don't check — a grep
  scoped to the files a change "should" touch confirms its own
  assumption.** Still open and **operator-side**: DESIGN-0024 and IMPL
  task 5.7 both require the default-change note in a **CHANGELOG that
  does not exist** anywhere in this repo (release notes come from a
  `### RELEASE NOTES` block in the PR body via `pr-semver-bump`), so
  whether the fleet gains a changelog convention is a call that interacts
  with per-module tagging and the planned Go release CLI.
  **`modules/eks/cluster/test/` is a libtftest Go integration suite** — the
  fleet's only one outside `tools/` — and Phase 3's *additive*
  `sso_principal_arn` output **broke it**: its `outputs_contract` subtest
  asserts an **exact** output count (`want 8`, now 9). Nothing caught it.
  The suite is `//go:build integration` tagged, CI touches the module only
  via `security.yml`'s `govulncheck` matrix, `just static` does not cover
  Go, and it needs a LocalStack container — **so no gate compiles or runs
  it.** The exact-count assertion is right and stays exact (the eks state
  shape is an ADR-0020 contract with five consumers; an accidental output
  *should* fail). Two takeaways: **"additive output" is not automatically
  safe** — grep for Go suites before assuming it — and a `go vet -tags
  integration` job would catch this class without needing a container.
  **`expect_failures` verification (IMPL-0020):** that block asserts only
  that a checkable object errored, **not which rule fired** — so with 8
  validations on `var.access_entries` and 4 preconditions on
  `aws_eks_cluster.this`, a run can pass off a *neighbouring* rule and look
  identically green. All were checked and pass honestly: the eight
  validations were re-run without `expect_failures` to read the actual
  message (eight distinct, each the intended rule), and the cluster's new
  fourth precondition was proven by **mutation** — neuter it, and
  `rejects_fence_that_expands_to_nothing` goes red with "Missing expected
  failure", confirming no other guard catches an emptied prefix list.
  **Reusable rule: a passing `expect_failures` run is evidence the object
  errored, not evidence your rule works.** Terraform rejects a constant
  `condition`, so mutate with an always-true expression that still
  references config (`length(var.x) >= 0`).
- **`modules/ecr/`** — `pull-through-cache` (IMPL-0005, implemented; previously
  lived at `modules/eks/ecr-pull-through-cache` and was relocated when
  DESIGN-0006 surfaced a second ECR module; the conftest credential gate's
  **first real catch** — its operator placeholder was migrated from persisted
  `secret_string` + `ignore_changes`, which read the operator-rotated real
  token back into state on refresh, to write-only `secret_string_wo` with a
  pinned `secret_string_wo_version = 1` as the version gate, raising the
  module to `required_version >= 1.11`; upgrading replaces the version
  resource and re-seeds the placeholder — see the README upgrade note).
  `org-registry` (IMPL-0006,
  implemented — the fleet-wide OCI artifact registry per RFC-0002 / ADR-0016).
- **`modules/rds/`** — `serverless` (IMPL-0007, implemented — Aurora Serverless
  v2 for Postgres + MySQL per DESIGN-0007). `instance` (IMPL-0011, implemented —
  a single non-clustered `aws_db_instance` for Postgres + MySQL per DESIGN-0012;
  **completes the DESIGN-0007 rollout** — serverless + cluster + read-replica +
  proxy + instance all shipped). Forks the `serverless` scaffolding, swapping the
  Aurora cluster + `db.serverless` for one `aws_db_instance` with the non-Aurora
  storage surface (`allocated_storage`, `max_allocated_storage` autoscaling [Q3 —
  no `ignore_changes`; the provider suppresses the `allocated_storage` diff for
  autoscaling growth while deliberate resizes still apply], `storage_type`
  gp2/gp3/io2, `iops`, `storage_throughput`, `multi_az`); a single
  `aws_db_parameter_group` (no cluster group); 5 preconditions (parameter-family,
  final-snapshot, `max>=allocated`, monitoring-role, io2-requires-iops); uses
  `aws_db_instance`'s `username` arg (NOT the Aurora `master_username`). Emits the
  7 proxy-composition outputs so it is a valid `rds-instance` proxy target.
  **Test divergence (Q5-b, same Pro-gated split as `proxy`/`cluster`/`read-replica`):**
  plan-only `tests/` (26 runs) is the gate, `tests-localstack/` a Community
  `plan_smoke` (2 runs, offline-verified), and the Pro apply lives in
  `tests-localstack-pro/` (off by default, `just tf test-localstack-pro
  rds/instance`; the apply sets `deletion_protection=false` +
  `skip_final_snapshot=true` for `terraform test`'s teardown since LocalStack Pro
  enforces deletion protection on a standalone `aws_db_instance`; `engine_version=16`
  pin + macOS named-volume caveat, same as siblings) — live Pro apply **run and
  passing, 3/3 against LocalStack Pro 2026.6.2** (named volume). `cluster`
  (IMPL-0012, implemented — Aurora **provisioned**
  single-writer cluster for Postgres + MySQL per DESIGN-0013). It is the
  `serverless` module with two edits: no `serverlessv2_scaling_configuration`
  block (and no `min_acu`/`max_acu`) and a concrete `var.instance_class` in
  place of the `db.serverless` sentinel. Adds `storage_type`
  (Standard/`aurora-iopt1`), `backtrack_window` (Aurora-MySQL-only, guarded by a
  cluster precondition), `enabled_cloudwatch_logs_exports`, and `promotion_tier`
  (writer defaults 0). Emits the 4 proxy-composition outputs, so it is a valid
  `aurora-cluster` proxy target, and is the **source-of-truth remote state** for
  the `read-replica` module (IMPL-0013) at
  `<region>/rds/cluster/<identifier_prefix>/terraform.tfstate` (consumer set:
  cluster_identifier, cluster_resource_id, engine, engine_version_actual,
  db_subnet_group_name, db_parameter_group_name). **Test divergence (Q5-b, same
  as `proxy`):** a provisioned cluster instance boots a real embedded PostgreSQL
  (Pro-only), so the plan-only `tests/` suite (19 runs) is the gate,
  `tests-localstack/` holds a Community `plan_smoke` (verified offline), and the
  Pro apply lives in `tests-localstack-pro/` (off by default, run via `just tf
  test-localstack-pro rds/cluster`; same macOS named-volume + `engine_version=16`
  caveats as `serverless`/`proxy` — live Pro apply **run and passing, 3/3
  against LocalStack Pro 2026.6.2** via a direct `docker run` named volume, since
  `lstk` only does host bind mounts). `read-replica` (IMPL-0013, implemented —
  one or more Aurora reader instances (`aws_rds_cluster_instance`) attached to an
  existing `cluster` per DESIGN-0014). Structurally a fork of `proxy`: a **pure
  cluster remote-state consumer** (owns no cluster/subnet-group/SG/KMS) with a
  tiny pointer surface + a `for_each` over a typed hybrid `replicas` map(object)
  (required `instance_class`; optional `availability_zone`, `promotion_tier`
  default 15, PI, monitoring, etc.). engine/version/subnet-group/parameter-group
  inherited from the cluster's remote state (drift-proof, Q5); 3 preconditions
  (stale-state, composed-identifier ≤63, per-reader monitoring role). Emits
  per-reader `replica_identifiers` + `replica_endpoints` maps (the cluster's
  `reader_endpoint` stays the load-balanced entry). **Test divergence (Q3, same
  Pro-gated split as `proxy`/`cluster`):** plan-only `tests/` (11 runs) is the
  gate, `tests-localstack/` a Community `plan_smoke` (offline), and the Pro apply
  in `tests-localstack-pro/` (off by default, `just tf test-localstack-pro
  rds/read-replica`) bridges real cluster state through an S3 object — its
  `fixtures/cluster` instantiates the **actual `cluster` module** (Q4-b) with a
  `depends_on` on the module to defer its VPC-state read. Live Pro apply **run
  and passing, 2/2 against LocalStack Pro 2026.6.2** (named volume). `proxy` (IMPL-0010, implemented — Amazon RDS Proxy in front of any data-tier
  target per DESIGN-0010 / RFC-0002). Composes via the target's remote state
  (ADR-0001, `var.target_type` ∈ {rds-instance, aurora-cluster, serverless}),
  reuses the AWS-managed master secret (IAM role least-privilege
  GetSecretValue + kms:Decrypt), V1–V7 plan-time validations (V1/V6/V7 variable
  validations, V2–V6 preconditions), TLS-on default, optional Aurora READ_ONLY
  endpoint. Postgres + MySQL both supported (engine_family/port derived from the
  target's `engine` in remote state, so no proxy/target drift). Phase 2 added
  four proxy-composition outputs to `serverless` (`db_subnet_ids`, `vpc_id`,
  `master_user_secret_kms_key_arn`, `iam_database_authentication_enabled`);
  `cluster` now emits the same set, and the unbuilt `instance` module must too.
  **Test divergence
  (Q7):** RDS Proxy is LocalStack-Pro-only, so coverage splits — the plan-only
  `tests/` suite is the gate; `tests-localstack/` holds a Community-safe
  `plan_smoke`; the Pro apply lives in `tests-localstack-pro/` (off by default,
  run via `just tf test-localstack-pro rds/proxy`). The live Pro apply was run
  and passes (3/3 against LocalStack Pro 2026.6.0). **macOS gotcha:** the Pro
  RDS apply needs `/var/lib/localstack` on a Docker **named volume**, not a host
  bind mount (the `lstk` default) — Docker Desktop's file-sharing ignores
  `chown`, so LocalStack's embedded Postgres `initdb` fails on data-dir
  ownership. Run LocalStack Pro directly with a named volume for these tests
  (see the module's `tests-localstack/FINDINGS.md`). **Master-secret rotation
  + manage-false guardrail (INV-0008 / IMPL-0017):** the three secret-owning
  modules (`instance`, `serverless`, `cluster`) share an identical surface —
  `master_secret_rotation_days` (number, default 90, `null` = leave AWS's
  7-day default alone, validation 7–365) driving a count-gated
  `aws_secretsmanager_secret_rotation` in each module's `secret_rotation.tf`
  that adopts the AWS-managed master secret (`rotate_immediately = false`,
  no lambda; omitted when `manage_master_user_password = false`), plus a
  precondition on the DB resource (`manage || iam_auth`) so the
  no-auth-path combination (`manage = false` without IAM auth — no password
  input exists by design) fails at plan, mirroring `rds/proxy`'s fail-closed
  consumer precondition. LocalStack Pro 2026.7.0 parity gap: it mints the
  managed secret without a managed-rotation registration, so the rotation
  resource cannot apply there — apply suites pass
  `master_secret_rotation_days = null`; the plan suites gate the surface.
  Live deployments pick up the 90-day schedule on their next apply: the
  rotation resource adopts the existing managed secret in place
  (schedule-only — no secret replacement, no credential change).
- **`modules/efs/`** — `filesystem` (IMPL-0008, implemented — the AWS-API
  companion to the EKS addons module's already-installed `aws-efs-csi-driver`
  per DESIGN-0008). The `filesystem/` sub-directory leaves room for future
  siblings (e.g. `modules/efs/replica/` if cross-region replication ever lands).
- **`modules/bedrock/`** — `claude-code` (IMPL-0009, implemented — Claude Code
  on Bedrock governed access + cost attribution per DESIGN-0009 / RFC-0003).
  Provider-agnostic at the Bedrock layer: IAM user + least-privilege policy,
  one application inference profile (AIP) per `var.models` entry, SNS + email
  (optional Slack) alerting, tag-filtered AWS Budget, per-AIP CloudWatch
  token alarm, conditional cost-allocation tag activation. The credential
  (bearer token) is deliberately NOT minted by Terraform — see
  `tools/bedrock-keyctl` below. The `claude-code/` sub-directory leaves room
  for siblings like `modules/bedrock/guardrails/`.
- **`modules/network/`** — `vpc-lookup` (from INV-0004, implemented — the
  read-only, **zero-resource** producer of the VPC remote-state contract every
  data-tier/compute module already consumes). INV-0004 surveyed all six
  consumers (`eks/cluster`, `eks/managed-node-group`, `rds/{serverless,cluster,
  instance}`, `efs/filesystem`) and found the contract is exactly two stable
  outputs — `vpc_id` (string) + `private_subnet_ids` (list, ≥2 AZs) — published
  at state key `${region}/vpc/${name}/terraform.tfstate`. This module discovers
  an **existing** VPC via `data` sources (`aws_vpc`/`aws_subnets`/`aws_subnet`/
  `aws_nat_gateways`/`aws_route_tables`/`aws_internet_gateway`) — by `tag:Name =
  var.name` (default) or explicit `var.vpc_id`. Subnets resolve as a **three-tier
  topology** discriminated by a `Network` tag (`Public` / `Private` / `Private
  EKS`); the `kubernetes.io/role/{elb,internal-elb}` tags are passive (AWS
  Load-Balancer-Controller auto-discovery, not a module filter). It re-publishes
  the two contract outputs plus 7 additive ones (`private_eks_subnet_ids` — the
  internal cluster IP range for `eks/cluster`'s `vpc_config`, `public_subnet_ids`,
  `vpc_cidr_block`, `availability_zones`, `nat_gateway_ids`, `route_table_ids`,
  `internet_gateway_id`). `private_subnet_ids` stays the data tier (RDS/EFS +
  EKS worker nodes); a follow-up rewires `eks/cluster` to `private_eks_subnet_ids`.
  It ships **first** as the stand-in that exercises the
  consumption contract before the full **create-or-adopt** `modules/network/vpc`
  (brownfield import-first, explicit per-AZ subnet CIDR maps, `for_each`-by-AZ
  addressing, single NAT default — all decided in INV-0004) is built. **Testing
  (no divergence, Community-safe):** plan-only `tests/` (2 runs, mock_provider +
  override_data) is the gate; `tests-localstack/` is a **real Community apply**
  (3 runs) — pure EC2/VPC API needs no Pro tier / no token / no named volume,
  run and passing 3/3 against token-free `localstack/localstack:4.4`
  (`SERVICES=ec2,sts`). The `vpc-lookup/` sub-directory leaves room for
  `modules/network/vpc` + siblings (`network/{tgw,peering,endpoints}`).
  `security-group` (DESIGN-0026 → IMPL-0023, implemented; **shipped as
  `v0.25.0`**, PR #116 merged 2026-09-12) — the
  standalone **ingress-allowlist** SG producer, generalizing INV-0011
  F1 batch 4's Gateway frontend-SG proposal. It productizes
  `eks/cluster`'s granular-rule idiom: typed `ingress_rules` /
  `egress_rules` `map(object)` driving one
  `aws_vpc_security_group_{ingress,egress}_rule` per entry keyed by
  **logical name**, so removing one allowlist entry is a single destroy
  that never churns a sibling. Each rule names exactly one of
  `cidr_ipv4` / `cidr_ipv6` / `prefix_list_id` /
  `referenced_security_group_id`. **Prefix-list rules are LIVE** — the
  deliberate counterpart to `eks/cluster`'s endpoint fence, which
  expands lists at *plan* time because the EKS API takes literal CIDRs;
  the two READMEs now cross-link in both directions. Seventh vpc
  consumer; publishes at the NEW ADR-0020 **`sg`** shape
  (`<acct>/<region>/sg/<name>`), reserved ahead of its first consumer
  the way `iam` and `secrets` were. **The fleet's first
  `required_version = ">= 1.9"`**: the world-open guard is a
  *cross-variable* validation (`ingress_rules` reading
  `allow_world_open_ingress`), which TF only accepts from 1.9 — and the
  failure mode of lowering the floor is quiet, since below it the guard
  stops being accepted rather than erroring loudly. The guard tests
  **`endswith(cidr, "/0")`, not string equality** — it originally
  compared against `"::/0"`, and the security review below proved
  `0::/0` and the fully-expanded spelling both planned *clean* with the
  toggle false (upstream provider issue #15982, reproduced in our own
  guard). `/0` is the only prefix length whose literal text ends in
  `/0`, so the suffix test is exact; the v4 side was safe only by luck
  (the provider's validator accepts exactly one v4 `/0` spelling).
  **The guard's boundary is deliberate and documented, not closed:** it
  inspects literal CIDR fields only, so a prefix list containing
  `0.0.0.0/0` admits the world invisibly — expanding a *live* reference
  at plan would be false assurance, so prefix-list contents are the
  list owner's audit surface — and it does not catch a **`/1` split**
  (`0.0.0.0/1` + `128.0.0.0/1` is the whole internet in two non-`/0`
  rules; catching that means CIDR arithmetic across the whole map, and
  any threshold chosen rejects legitimate large allowlists). It guards
  the *accident*, and the README says exactly that.
  (`referenced_security_group_id` has no
  equivalent hole: an SG reference admits that SG's members, never the
  world.) Egress deliberately has **no** world-open guard (OQ 2a) —
  world egress *is* the default posture: `allow_all_egress = true`
  emits one explicit all-protocols rule (the `nodes_all` shape), which
  exists because **the provider revokes AWS's default egress at
  create**, so a surface-less module would ship SGs that silently fail
  ALB health checks; `allow_all_egress` **+ a non-empty `egress_rules`
  is rejected at plan** (it used to be additive — a silent widening,
  since the all-egress rule is wider than anything a restricting caller
  writes and appears in the plan only as an *unchanged* resource), and
  the logical key `all-egress` is reserved.
  `name_prefix` + `create_before_destroy` (never a fixed
  name: SG name/description are create-time, and a destroy-first
  replacement of an ALB-attached SG deadlocks on
  `DependencyViolation`) — but a replacement still mints a new SG id,
  which CBD does *not* fix. **DESIGN-0026 deviation, recorded:** the
  design's object spec makes `from_port` required *and* requires `-1`
  to omit ports — mutually exclusive, and it would have made the
  module's own all-egress default illegal under its own guard; the
  type is `optional(number)` with the coherence moved to validation.
  Tests: plan `tests/` 33 runs (the gate — all four source types in one
  plan, each asserting its own field is set *and* all three others null;
  a bare call pinning every default; 22 rejections each **verified by
  isolated message-probe** to fire its own rule at its own line, since
  many validations stack on `ingress_rules` alone) + Community apply
  4/4 on token-free 4.4 (`SERVICES=ec2,sts,s3`).
  **Adversarial security review (IMPL-0023, `iac-security`, pre-merge)**
  closed two HIGH and several MEDIUM holes, both HIGHs reproduced before
  fixing: the IPv6 spelling evasion above, and — the one worth carrying
  fleet-wide — **the module's own default `description` contained a
  U+2014 em dash**, which the EC2 `GroupDescription` ASCII charset
  rejects, so every non-overriding invocation would have failed at
  *apply* against real AWS. Neither gate could see it: the constraint is
  server-side, and **LocalStack does not enforce AWS string-charset
  constraints** — the apply suite had *pinned the broken value as
  expected*. **Reusable rule: an emulator proves shape and wiring, never
  a provider's server-side string contracts; charset/length/format must
  be validated at plan or they are not validated at all, and a green
  apply tier is actively misleading about them.** MEDIUMs: ICMP's
  `to_port` is the **CODE**, not a range end, so the collapse made
  `{from_port = 8, ip_protocol = "icmp"}` plan as type 8/code 8 and
  match nothing (three-way port coherence now requires both, with a
  *positive* ICMP run so the rejection can't be satisfied by a rule that
  rejects all ICMP); inverted ranges; an unvalidated `ip_protocol`; the
  additive-egress widening; the reserved `all-egress` key; untested tags
  on typed egress rules; and four "sets X and nothing else" assertions
  that checked one of three siblings. **The re-probe caught a defect in
  the new tests themselves** — `unknown_ip_protocol_rejected` fired two
  rules — which is the standing lesson paying off in the same session:
  adding validations to a variable that already carries several is
  exactly how a neighbouring rule starts answering for yours.
  **All three fixes are mutation-verified** (scratch copy outside the
  repo): reverting the guard to the string compare leaves both
  pre-existing world-open runs **green** while the two new ones fail
  with *"Missing expected failure"* — i.e. the bad input planned
  clean, so the hole was reachable; neutering the charset regexes to
  `.*` reds exactly the two charset runs; and neutering the ICMP branch
  to reject **every** ICMP rule leaves
  `icmp_rule_without_explicit_code_rejected` **passing** while only the
  positive run goes red. **That last one is the IMPL-0024 RE2 trap in
  another costume: any validation whose correctness depends on what it
  lets *through* needs a run that passes**, because a fail-case run is
  green whether the rule discriminates or rejects everything.
  **New fleet finding:
  token-free Community 4.4 serves managed prefix lists *including
  entries*** — previously only proven under **Pro** (the `eks/cluster`
  fence fixture), so what needed Pro there was EKS, not the prefix
  lists beside it. The apply reads the rule back through
  `data.aws_vpc_security_group_rule` and asserts the `pl-…` survived
  (mutation-verified): asserting only that the rule got an `sgr-…` id
  would pass even if the live reference had been dropped.
  **Design-conformance audit (DESIGN-0026 read end-to-end against the
  shipped code):** functional surface complete; everything that drifted
  was prose — the same shape as IMPL-0020's audit. Corrected: the design
  still specified the **additive** egress posture the module now rejects
  and the **string-compare** world-open guard that was HIGH-1 (a call
  site written from either would fail); `SERVICES=ec2,sts` where the
  fixture needs `s3` too; the validation suite's own
  verification-discipline header frozen at a Phase-1 snapshot; and four
  OQ citations pointing at DESIGN-0026's OQ 1/2 (VPC resolution, naming
  posture) for decisions that are **IMPL-0023's** — worth watching for,
  since a design and its IMPL both have an "OQ 1". Also: task 1.7
  claimed a `create_before_destroy` pin, but **`lifecycle` is a
  meta-argument and is not assertable from `terraform test` at all** —
  not merely unmet, unachievable in that form.
  **Fleet-wide finding, probed not inferred — `name_prefix` + `import`
  = REPLACEMENT.** The provider infers `name_prefix` on read by
  stripping **exactly 26 characters** off the physical name, so an SG
  created by hand as `gateway-frontend-public` leaves `name_prefix`
  unset in state and the module's `name_prefix = "gateway-frontend-public-"`
  lands on a **ForceNew** argument: `1 to import, 1 to add, 1 to
  destroy`. The control — a name whose last 26 chars strip to exactly
  the prefix — imports with `0 to destroy`, which is what identifies
  the mechanism rather than just the symptom. CBD survives it but the
  **id changes** on a live ALB-attached group. **This applies to every
  `name_prefix` module in the fleet** — verified, not assumed:
  `aws_secretsmanager_secret` reproduces it exactly (`1 to import, 1 to
  add, 1 to destroy`), and those are the only two modules using the
  provider's `name_prefix` *argument* (the ECR ones interpolate a
  `var.name_prefix` string into `name`, where no inference happens). So
  any "adopt an existing X" runbook must say so instead of promising a
  zero-diff import. **On `secretsmanager/secret` the consequence is
  worse than on an SG and is an open follow-up:** that resource has no
  `create_before_destroy` and its value is a fresh
  `ephemeral.random_password` on every create, so a replacement is
  destroy-then-create **with a new credential** — every consumer
  holding the old value breaks, and SM reserves the deleted name for
  the recovery window. Its README has no adoption section today (so
  nothing false shipped), and adding one is where that caveat belongs.
- **`modules/s3/`** — the S3 bucket family (INV-0009 → DESIGN-0019 →
  IMPL-0018; extended by DESIGN-0022 → IMPL-0021 with the evidence
  tier + lifecycle tiering). Architecture: thin purpose modules over one shared
  **internal core** at `modules/s3/internal/core` (IMPL-0018 Phase 1,
  implemented), consumed ONLY via the relative path
  `source = "../internal/core"` so the core rides each purpose module's tag —
  **the core must never gain a versioned source** (registry/git-ref; the
  DESIGN-0019 nesting-exemption condition, grep-enforced in Phase 5). The core
  owns the F2 baseline: composed naming `<name>-<account_id>-<region>` (+
  opt-in 5-char `random_string` shard prefix — `random ~> 3.7`, a fleet first;
  toggling it replaces the bucket), fixed PAB + BucketOwnerEnforced, SSE-KMS
  `aws/s3` + bucket key default (CMK override; `mode = "s3"` AES256 for the
  access-logs sink), versioning off default, MPU-abort 7d + typed
  `extra_lifecycle_rules`, composed policy (fixed `DenyInsecureTransport` +
  `DenyOldTls` reserved sids, opt-in `DenyOutsideVpce`, additive-only typed
  `internal_policy_statements` with reserved-sid validation and
  `resource_suffixes` relative to the bucket ARN), caller-resolved `logging`
  object (null prefix → `<composed-name>/`, self-logging precondition), and
  the attribute-derived `security_baseline` output (the purpose modules' only
  test window — child-module resources aren't assertable in `terraform test`;
  `kms_key_arn` is a documented input-echo exception since the attribute is
  Optional+Computed → unknown at plan). **Plan-knowability invariant:** policy
  composition uses the deterministic `local.bucket_arn`
  (`arn:aws:s3:::<name>`), NOT the resource's unknown-at-plan `arn` attribute.
  Core plan suite: 19 runs green. CI plumbing shipped with Phase 1: the
  justfile `tf_test_varfile` is now `justfile_directory()`-absolute (the old
  three-`../` relative path broke at the core's depth-4 dir), and
  `scripts/changed-modules.sh` gained the internal-module fan-out (a diff
  under `modules/<service>/internal/**` re-tests every leaf module of that
  service; self-test 25/25). `access-logs-bucket` (Phase 2, implemented) is
  the first purpose module: the fleet's server-access-log sink singleton —
  SSE-S3 pinned (log delivery can't write to SSE-KMS targets), the
  `AllowS3ServerAccessLogDelivery` grant (Service principal +
  `aws:SourceAccount` condition, objects-only), `log_retention_days`
  default 90 (`null` = keep forever) via the core's `extra_lifecycle_rules`,
  published at the **flat reserved ADR-0020 key**
  `<account_name>/<region>/s3/access-logs/terraform.tfstate` (no `<name>`
  segment — `access-logs` is a reserved stack name; non-default sinks =
  another live-repo folder + consumer `target_bucket` override, no key
  contract). Its `security_baseline.tftest.hcl` is the family baseline
  suite's documented **F3 variant** (AES256/no-KMS); the byte-identical
  diff-guard pair (Phase 5) is `bucket`/`events-bucket`. **Wrapper-module
  gotcha (Phase 2):** a purpose module with no direct aws resource MUST
  still declare aws in root `required_providers` (tflint-ignored as
  unused) — without it `terraform test` can't bind the test-file
  `provider "aws"` block and every plan run fails resolving real
  credentials. The core grew a `lifecycle_rule_ids` output so purpose
  suites can pin rule wiring at plan. Tests: plan `tests/` (6 runs, the
  gate) + a real Community apply in `tests-localstack/` (1 run, token-free
  `localstack/localstack:4.4`, `SERVICES=s3,sts`, `s3_use_path_style` —
  run and passing). `bucket` (Phase 3, implemented) is the
  general-purpose bucket and the family's reference consumer: the F4
  `access_logging` tri-state (default `{}` = look the sink up at the flat
  reserved key / explicit `target_bucket` / `enabled = false`) driving the
  fleet's **first count-gated remote-state read** — the two non-default
  paths create no data source at all, so they neither need the producer
  nor pay the bootstrapping order (ADR-0020 now records this
  conditional-read pattern). Resolution is
  `coalesce(override, one(data...[*].outputs.bucket_name))`; the core
  resolves a null prefix to `<composed-name>/`. Adds
  `additional_policy_statements` (OQ 4b additive pass-through; the
  reserved-sid guard is **mirrored onto the root variable** because
  `expect_failures` cannot target a child module's validation). Tests:
  plan `tests/` (9 runs — all three paths, the ADR-0020 key assertion via
  `override_data`, additive merge) + Community apply (3 runs, **run and
  passing**) whose `fixtures/access-logs` applies the **real** sink
  module and seeds the reserved key, proving the account-scoped +
  `assume_role` read end to end without any VPC. **F6 probe 1 →
  NEGATIVE:** LocalStack 4.4 round-trips the `PutBucketLogging` config
  but never materializes delivered log objects, so per DESIGN-0019 OQ 6a
  the suites assert the config surface only (`logging_target` /
  `logging_prefix`), never delivery. **`terraform test` gotchas found
  here:** a variable-validation failure does NOT short-circuit
  data-source evaluation (an `expect_failures` run on the default
  tri-state still attempts a real S3 read — disable logging in those
  runs), and there is no `setequal()` function (use
  `toset(a) == toset(b)`). `events-bucket` (Phase 4, implemented) is
  `bucket` plus notification.tf: one `aws_s3_bucket_notification` (a
  **per-bucket singleton** — the API replaces the whole configuration on
  every write, so all destinations live in that single root resource
  where plan suites can assert them), typed `sqs_queues`/`sns_topics`
  lists (unique ids, non-empty events, per-entry prefix/suffix filters)
  + `eventbridge_enabled`, and an at-least-one-destination precondition
  (no "notifications off" mode — use `bucket` for that). Destination
  resource policies belong to the **destination** stacks; the apply
  fixture is the worked example. Tests: plan 13 runs + Community apply
  3 runs (**run and passing**, `SERVICES=s3,sts,sqs,sns,events`). Its
  `security_baseline.tftest.hcl` is byte-identical to `bucket`'s — the
  destination its precondition needs rides in the file-level
  `variables` block, exploiting a confirmed `terraform test` behavior:
  **a test-file `variables` block silently ignores variables the module
  under test doesn't declare, exactly like `-var-file`**. **F6 probe 2 →
  POSITIVE** (LocalStack delivers the `s3:TestEvent` handshake + a full
  `ObjectCreated:Put` record), but the baked depth stays the config
  surface because `terraform test` cannot receive an SQS message — here
  the harness is the limiter, not the emulator (inverse of probe 1). A
  second probe found LocalStack does **not** enforce destination
  policies (real S3 returns `InvalidArgument` for a policy-less queue),
  so the apply demonstrates the queue-policy shape without verifying it.
  **IMPL-0021 (DESIGN-0022, 2026-09-04)** added the evidence tier: the
  core grew `object_lock` (default `{}` = hard no-op — explicit
  `object_lock_enabled = false` is the provider's absent-argument
  equivalent, so every pre-existing bucket replans zero-diff, pinned
  by a default run) with a mode enum, days-xor-years, and the
  **retention-set-but-disabled coherence guard** (`{ days = 400 }`
  without `enabled = true` fails at plan instead of silently
  configuring nothing — the IMPL-0020 silent-widening lesson applied),
  a versioning-coupling precondition, a count-gated
  `aws_s3_bucket_object_lock_configuration` (lock-on with no duration
  is legal: per-object retention only), and an attribute-derived
  `object_lock` output (null without default retention — rides its
  own output so the shared `security_baseline` shape is untouched,
  OQ 7a). The lifecycle type gained `transitions` +
  `noncurrent_version_transitions` (storage-class validated; per-rule
  day ordering left to the S3 API) and the F5 gaps closed (core 19 →
  31 runs). `bucket`/`events-bucket` expose the full typed
  `lifecycle_rules` + `lifecycle_rule_ids` re-export with the
  reserved-rule-id guard mirrored at both roots (the reserved-sid
  pattern; 11/15 runs, diff-guard pair untouched).
  **`evidence-bucket`** (NEW) pins versioning + lock (no variables),
  maps required `retention` (COMPLIANCE default, exactly one of
  days/years — OQ 1a: no default duration) onto the core, carries the
  full reference-consumer surface, and its `security_baseline` suite
  is the family's **second documented variant** (versioning Enabled;
  static-check's diff loop is an events-bucket-only allowlist, so
  variants need no exclusion edit — but the guard comment names
  them). Community apply 1/1 on token-free 4.4; **probe B POSITIVE**:
  4.4 Community *enforces* COMPLIANCE retention (version delete →
  AccessDenied), so never write objects in a locked-bucket apply
  suite — teardown would be undeletable until retention expires
  (suite keeps `days = 1`, writes nothing; enforcement recorded in
  FINDINGS.md, config-surface assertions only per OQ 2a).
  Remaining: `cloudfront-origin-bucket` + `presigned-transfer-bucket`
  deferred.
- **`modules/iam/`** — `role` (DESIGN-0025 → IMPL-0022, implemented;
  **shipped as `v0.23.0`**, PR #112 merged 2026-09-09).
  One generic **trust-boundary** role module replacing the queued
  `iam/deploy-role` + `iam/cross-account-role` pair — identical resource
  surfaces, so the inputs define what an instance is. Producer-only (no
  remote-state read, none of the six globals), `required_version >= 1.1`
  (every validation is single-variable). Fail-closed trust:
  `trusted_role_arns` carries **five separate validation blocks**
  (non-empty / exact `role|user` ARN regex / wildcard rejection /
  no surrounding whitespace / duplicate rejection **compared
  normalized** as lowercased path-stripped `<account>/<name>`, the
  IMPL-0020 collision-guard rule) so each rejection run is verifiable
  against the rule it names; there is deliberately **no
  service-principal channel and no raw-JSON trust escape hatch**
  (resource-owning modules mint their own
  service roles). Policy channels mirror `eks/pod-identity-access` in
  shape, and as of **DESIGN-0027 Part B / IMPL-0024 the mirror is
  honest in both directions**: all four validations (the two channel
  regexes, `can(jsondecode())` on `inline_policies`, and the
  null-or-ARN rule on `permissions_boundary`) now exist on **both**
  modules. That backport was not cosmetic — `pod-identity-access`
  had **zero** validation on that surface, so it carried IMPL-0022's
  F1 (an empty-string boundary yielding an unbounded role) and F2
  (cross-channel duplicate ARNs silently surviving a revocation) as
  live defects on a module shipped since `v0.21.0`.
  **`aws_iam_policy_document` rendering gotcha
  (probed, pinned by two runs):** it collapses single-element sets, so
  `Principal.AWS` is a **string** with one principal and a **list** with
  two or more (`Action` likewise, being a single action) — an assertion
  written for one shape silently proves nothing on the other. A
  non-default `path` gives one role two legitimate ARN spellings; keep
  `path = "/"` for roles destined for an `eks/access-entries` binding
  until IMPL-0020 task 5.4's live runs settle EKS canonicalization.
  Publishes at the platform-reserved ADR-0020 **`iam`** shape
  (`<acct>/<region>/iam/<name>`), reserved ahead of its first consumer
  the way `secrets` was; the `<name>` coupling is **exact and doubly
  load-bearing** — it is both the state key segment and the string every
  `assume_role` block composes, so a rename is a deliberate role
  replacement, not a refactor. Tests: plan `tests/` 25 runs (the gate —
  both §4 shapes with the trust JSON asserted by *content*, a bare call
  pinning every default, channel
  address stability, 17 rejections each verified per-rule) + a Community
  apply 3/3 on token-free 4.4 (`SERVICES=iam,sts` — no Pro, no token, no
  named volume) whose `verify_readback` run reads the role back through
  `data.aws_iam_role` in its own fixture. **FINDINGS leads with the
  caveat that LocalStack STS mints credentials for any role ARN
  (IMPL-0015 Phase 1), so the suite never asserts assumability** — trust
  is enforced at plan by the four validations. **Import probe POSITIVE
  (OQ 4a):** an out-of-band role adopted via an `import` block inside
  `terraform test` applies clean and is torn down with the test; the
  control — the identical apply *without* the block failing 409
  `EntityAlreadyExists` — is what makes that evidence rather than a
  coincidence.
  **Adversarial security review (IMPL-0022, `iac-security`, pre-merge)**
  closed four real defects the module accepted at plan, each reproduced
  before fixing: (1) `permissions_boundary = ""` produced an
  **unbounded role** — the provider omits the argument on create and
  *deletes* the boundary on update, so `""` reads as "bounded" in a
  plan and applies as no boundary; it was the only security-relevant
  input with zero validations; (2) the **same ARN in both policy
  channels** made revocation a silent no-op (idempotent
  `AttachRolePolicy` → two resources over one real attachment; drop it
  from one channel and the policy fully detaches, then the next
  unrelated apply re-grants it, with the surviving *unchanged*
  attachment never printed in the plan); (3) the trust validations
  compared **raw strings**, so a trailing space, a case variant, or a
  path-stripped spelling all slipped through; (4) the documented
  apply-time backstop **does not exist cross-account** — IAM resolves
  a same-account principal to its unique id at policy save but stores
  a cross-account ARN as an unvalidated literal, so a typo applies
  green and leaves a **dangling principal** whoever later creates that
  role name inherits. Both worked examples are cross-account, so the
  claim was wrong exactly where the module is used.
  **Defect 2 is fixed structurally, not by a guard:** the two channels
  gained regexes partitioning on the account field (`aws` vs 12
  digits), which are mutually exclusive — so cross-channel duplication
  is unrepresentable and a `setintersection` precondition would be
  permanently unreachable (an unreachable guard is untestable and
  rots). The loosening hazard is comment-pinned at the variable.
  **Two reusable lessons:** a review-driven fix belongs at the tier
  that makes the bad state *unrepresentable* rather than merely
  rejected; and **a fail-closed guard documented with a backstop that
  doesn't exist in the deployment topology the module is for is worse
  than no guard** — it stops anyone from looking further. Also: no run
  had pinned the module's *defaults* (every run overrode
  `max_session_duration` and `permissions_boundary`), which is how
  defect 1 stayed invisible — a bare-call run now pins them.
  **Trust conditions shipped as `v0.24.0` (DESIGN-0027 / IMPL-0024
  Phase 1, PR #114 merged 2026-09-11):**
  `require_org_ids` (list — the fleet spans several orgs; `[]`
  default) and `external_id` (null default), composed by
  `local.trust_conditions` into a `dynamic "condition"` inside the
  **existing single statement**. That placement is a **security
  invariant**: IAM's three combining rules disagree — values within
  one condition **OR**, conditions within one statement **AND**,
  statements within one document **OR** — so splitting the two
  conditions across statements would silently turn "in our org AND
  presenting the external id" into "…OR…". Statement count is pinned
  at 1 in every conditions run. **Three probe findings worth
  carrying** (all from rendering the JSON *before* writing
  assertions): (1) **Go RE2 caps a bounded repeat at 1000**, so
  `regex("...{2,1224}$")` is an *invalid pattern* and `can()`
  swallows that into `false` — the rule would have rejected every
  value; charset and length are now separate rules, and the general
  lesson is that a `can(regex(...))` validation must be probed with a
  value that must **pass**, since every fail-case test stays green
  either way; (2) condition `values` collapse like `Principal.AWS` —
  one org id renders a **string**, two a **list**, so both
  cardinalities need their own run; (3) conditions sharing a test
  operator **merge** into one `StringEquals` object with two variable
  keys, so `length(Condition) == 2` is false — assert
  `keys(Condition.StringEquals)`. `aws:PrincipalOrgID`'s scope is
  documented honestly: it shrinks a dangling principal's blast radius
  for an **out-of-org** account and does **nothing** for a typo
  naming a nonexistent role inside the org. Correct ARNs stay the
  primary control.
  **Adversarial security review (IMPL-0024, `iac-security`,
  pre-merge): no HIGH, and no path found to widen the trust surface** —
  the structural fixes from the IMPL-0022 review held under direct
  attack. Worth carrying: `ForAllValues:StringEquals` **with an absent
  key evaluates TRUE**, the commonest way an IAM condition is silently
  ineffective — unreachable here only because `test` is hardcoded
  `StringEquals` with no set-operator prefix anywhere, which is what
  the `keys(Condition) == {StringEquals}` assertion exists to force
  review on. The one MEDIUM is a **composition hazard, not a module
  defect: never set `external_id` on the deploy role** — all 12
  `data.terraform_remote_state` `assume_role` blocks pass only
  `role_arn` + `session_name`, so every consumer plan fleet-wide dies
  `AccessDenied` on the **next** plan, separated from the apply that
  caused it (the backend does accept `external_id`; the fix is one
  line per block, in the same change). Two LOWs, both documentation:
  an external id is **not a secret** (AWS says so, and it lands in
  CloudTrail on both sides), and `require_org_ids` covers the
  **account-number** half of the typo space — the dangerous half,
  since a mistyped account is one you don't control. Deliberately not
  shipped: a `require_trust_conditions` guard for a computed input
  resolving to empty (IMPL-0020's fence-expands-to-nothing shape) —
  recorded as DESIGN-0027 Follow-up 1 with an explicit revisit
  trigger, because no consumer computes these inputs yet. **Reusable
  test lesson: `toset()` on a bare string is a conversion *error*, not
  a silent pass**, so the two-org assertion self-defends against the
  single-element collapse; and a run whose only assert is true of a
  pre-existing resource in shared state (`startswith(role_unique_id,
  "AROA")`) proves the apply didn't error and nothing more.
  **Open follow-up:** policy *creation* (`iam/policy` sibling),
  additive and expected soon.
- **`modules/secretsmanager/`** — `secret` (INV-0010 → DESIGN-0020 →
  IMPL-0019, implemented). The fleet's SM secret producer (INV-0010
  resolution 1b: producer first; the RDS reference mode follows): creates a
  customer-managed secret whose value — bare generated password or, when
  `username` is set, the RDS-format `{"username","password"}` JSON that
  `rds/proxy` requires — **never exists in state, plan output, or code**.
  Mechanics: local `ephemeral "random_password"` (random `~> 3.7`; chosen
  over the aws `aws_secretsmanager_random_password` for offline
  plan-testability) → write-only `secret_string_wo` gated by
  `secret_string_wo_version = var.secret_string_version` (steady-state
  applies are no-ops, rotation = bump the integer; consumers copying the
  value onward re-send on their own bump). **The fleet's first
  `required_version = ">= 1.11"`** (write-only args; do not "simplify"
  down). `name_prefix = "<name>-"` because SM reserves deleted names for
  the recovery window (`secret_recovery_window_days`, 0 = teardown path);
  the ADR-0020 `secrets` key couples to `var.name`, not the suffixed
  physical name. **`name_prefix` makes this module un-adoptable without
  a credential change — open follow-up, probed during IMPL-0023.** The
  provider infers `name_prefix` on read by stripping exactly 26
  characters off the physical name, so importing a hand-created
  `app-db-master` leaves it unset and the module's value lands on a
  ForceNew argument (`1 to import, 1 to add, 1 to destroy`, reproduced
  against 4.4). Unlike `network/security-group` there is **no
  `create_before_destroy`**, and the value is a fresh
  `ephemeral.random_password` on every create — so the replacement is
  destroy-then-create **with a new secret value**, breaking every
  consumer, while SM holds the old name for the recovery window. No
  adoption section exists in the README today, so nothing false has
  shipped; write the caveat when one is added. KMS: null default = AWS-managed `aws/secretsmanager` key
  and a **faithful null `kms_key_arn` output** (rds/proxy branches on it);
  BYO CMK required for cross-account. Outputs are **pointer-only** (F7 —
  arn/id/name/kms/version/username, never the value). **Test constraint:
  `mock_provider` is structurally impossible in this module** (rejects
  ephemeral resource types even at count 0, no `override_ephemeral`;
  INV-0010 F3.1/F3.2) — suites use the real-provider-fake-creds pattern.
  Plan suite: 19 runs (the gate) incl. the permanent **no-leak assertion**
  (`secret_string_wo == null` in a passing plan) and the count-gated
  `read_principals` resource policy (exact-ARN principals only, wildcards
  rejected at validation). Community apply: 4/4 against token-free
  `localstack/localstack:4.4` (`SERVICES=secretsmanager,sts`) — the live F4
  proof (bumping `secret_string_version` replaces the AWSCURRENT version
  id, read via the **plural** metadata-only
  `aws_secretsmanager_secret_versions` fixture; never the singular
  value-bearing data source). The generalized invariant is enforced
  fleet-wide by the `policy/` conftest gate (below). Publishes at the
  ADR-0020 `secrets` shape (`<acct>/<region>/secrets/<name>/…`; `<name>`
  couples to `var.name`, never the suffixed physical name). **Next piece
  of work (DESIGN-0020 Follow-up 1): the RDS reference mode** — a
  `master_password` object on `rds/{instance,serverless,cluster}` reading
  this producer's state, the value ephemerally → `password_wo`/
  `master_password_wo` (the ADR-0020 reserved consumer row). Deferred:
  raw policy-JSON escape hatch (OQ 3a — additive `read_principals` only
  until a concrete need), consumer-side proof (rides the RDS follow-up,
  IMPL OQ 3a), `secretsmanager/rotation-lambda` sibling (if ever).

### Shared test fixtures (`test/fixtures/`)

- **`test/fixtures/reference-vpc/`** — the fleet's single, shared,
  `vpc-lookup`-faithful VPC fixture (DESIGN-0016 / IMPL-0014). Stands up the
  three-tier `Network`-tagged topology (Public / Private / Private EKS, +passive
  `kubernetes.io/role/{elb,internal-elb}` tags) across three AZs with IGW + one
  NAT + public/private route tables, then seeds the **full nine-output**
  `vpc-lookup` remote-state contract into S3 at
  `${region}/vpc/${vpc_name}/terraform.tfstate`, every value computed from its own
  resources (it does **not** instantiate `vpc-lookup`). Inputs:
  `remote_state_bucket` / `vpc_name` / `region` (+ `vpc_cidr`, `az_letters`
  defaults). Outputs: the nine contract values **plus** `bucket_name` so composing
  fixtures (`rds/proxy`, `rds/read-replica`) can write their own state objects
  into the same bucket. Consumer apply-tests source this via `run "setup"` instead
  of hand-rolling a `Tier`-tagged, two-output stub. **Caveat:** the real NAT
  gateway makes each apply that uses it ~1–2 min slower on LocalStack (accepted
  cost of DESIGN-0016 decision 3a — full network-fact fidelity). Verified with a
  live LocalStack apply (all nine outputs seeded, tiers disjoint, 3 AZs). The RDS
  slice adopts it first (IMPL-0014): the three direct `data.terraform_remote_state.vpc`
  consumers — `rds/serverless` (Community `test-localstack`), `rds/cluster` +
  `rds/instance` (Pro `test-localstack-pro`) — now source it via `run "setup"` and
  their bespoke `fixtures/setup/` dirs are deleted (Phase 2, all three apply suites
  **run and passing 3/3** against LocalStack Pro 2026.7.0 on a named volume). The
  special-case fixtures now **compose** it (Phase 3): `rds/proxy`'s `fixtures/db`
  and `rds/read-replica`'s `fixtures/cluster` source `module.vpc` for the DB subnet
  group / cluster VPC and write their non-VPC stub state (target / cluster) into
  `module.vpc.bucket_name` — zero inline VPCs, zero `Tier`-tagged subnets remain
  under `modules/rds/` (proxy Pro apply 3/3, read-replica Pro apply 2/2). The
  plan-time `data.terraform_remote_state.vpc` `override_data` stubs across the
  `serverless`/`cluster`/`instance` plan suites (68 blocks) were likewise expanded
  from the two-key form to the full nine-key contract (Phase 4, values-only —
  plan tests create no VPC). IMPL-0014 (all five phases) + DESIGN-0016 are
  **Implemented**; EKS (DESIGN-0015 addendum) + EFS (DESIGN-0017) follow.
- **`test/fixtures/terragrunt-inputs.tfvars`** — the fleet-wide shared var-file
  (INV-0005 / IMPL-0015) carrying the **six Terragrunt-provided globals** every
  remote-state consumer needs (`account_name`, `account_id`, `region`,
  `remote_state_bucket`, `remote_state_bucket_region`, `deploy_role_name`). In
  production Terragrunt injects these via includes into every module regardless
  of use; this file is the test-time stand-in. The `just tf test*` recipes pass
  it to `terraform test` via `-var-file` (hoisted into the `tf_test_varfile`
  justfile variable). Producer-only modules that declare none of these emit no
  error (and, in `terraform test`, not even a warning) — matching Terragrunt's
  pass-every-input design (Q6a). **IMPL-0015 is Implemented** (all six phases):
  the migration rewired every `data.terraform_remote_state` read across the fleet
  from the region-scoped key (`${region}/<shape>/…`) to the Terragrunt-faithful
  **account-scoped key** (`${account_name}/${region}/<shape>/…`) with a
  cross-account `assume_role` block
  (`role_arn = arn:aws:iam::${account_id}:role/${deploy_role_name}`,
  `session_name = "Deploy-Tf"`), `region = ${remote_state_bucket_region}`. Phase 1
  proved on LocalStack that the global `AWS_ENDPOINT_URL` routes both STS
  `AssumeRole` and S3 — no `endpoints{}` block needed, and LocalStack STS mints
  creds for any role ARN (no pre-created IAM role). `reference-vpc` gained
  `account_name` + `remote_state_bucket_region` inputs/outputs and seeds the
  **account-scoped key only** (content hoisted into `local.vpc_state_content`;
  the Phase-2 transitional dual-seed of the legacy region-scoped key was removed
  at the end of Phase 3). **All ten consumers migrated** — the five RDS
  (`serverless`/`cluster`/`instance` VPC reads, `proxy` target read,
  `read-replica` cluster read), the four EKS (`cluster` VPC read;
  `managed-node-group` reads **both** eks + vpc; `addons` + `pod-identity-access`
  eks reads), and `efs/filesystem` (reads **both** vpc + eks) — for **12
  `data.terraform_remote_state` blocks total, all 12 carrying `assume_role`**.
  Apply suites consolidated onto the shared `remote_state_bucket`; composing
  fixtures (`proxy/fixtures/db`, `read-replica/fixtures/cluster` — the latter
  threading the globals into the **real cluster module**) and the EKS/EFS bespoke
  `fixtures/setup` seed account-scoped keys. Plan suites need no per-suite edits
  (the var-file supplies the four new vars); only apply/setup files that reference
  `var.<new>` in a `run "setup"` block gained top-level `variable {}`
  declarations. Verified live: every plan gate green; Community applies
  (serverless, all four EKS, efs) and Pro applies (cluster/instance/proxy 3/3,
  read-replica 2/2) all pass; fidelity grep clean (zero region-scoped consumer
  keys, zero un-prefixed fixture keys). Each consumer's `tests-localstack*/
  FINDINGS.md` records the account-scoped-read + assume_role-on-LocalStack note.

The design and decision rationale for the fleet lives in `docs/adr/`
(ADR-0001..0020), `docs/rfc/` (RFC-0001..0003), `docs/design/`
(DESIGN-0001..0017), and `docs/investigation/` (INV-0001..0008). Phase-based
implementation tracking lives in `docs/impl/` (IMPL-0001..0017).

**Remote-state key contract (ADR-0020):** every cross-module read composes
the account-scoped key `<account_name>/<region>/<shape>/<name>/terraform.
tfstate` (`shape` ∈ vpc / eks / rds/{instance,cluster,serverless}) — but the
producer's actual key comes from the Terragrunt live repo's folder layout,
which this repo cannot see. `<name>` is triple-coupled (producer
identifier == live-repo folder == consumer input, e.g. `identifier_prefix`
== `target_identifier` for `rds/proxy`). Each consumer's plan suite pins its
composed `config.key` with an ADR-0020 assertion (the `target_dir_map` in
`rds/proxy` is pinned for all three target types); each affected module's
README carries a "Remote-state key contract" section. A wrong path fails the
consumer plan loudly but vaguely (`Unable to find remote state` — no
bucket/key in the error). The live-repo folder-naming leg is deliberately
unenforced here (belongs in the live repo).

### In-tree Go tooling (`tools/`)

- **`tools/bedrock-keyctl/`** — the repo's first in-tree Go CLI (IMPL-0009
  Part II, implemented). Own `go.mod`
  (`github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl`),
  Go 1.26.4. Mints/rotates/revokes the IAM service-specific credential
  Claude Code consumes via `AWS_BEARER_TOKEN_BEDROCK` and enables Bedrock
  model access per provider. Architecture: interface-first (`internal/awsapi`
  IAM/Bedrock/Marketplace/STS clients, `internal/sink` secret sink), an
  opaque `internal/credential.SecretValue` (redacting `String`/`MarshalJSON`
  + `Reveal(SinkToken)`) that enforces the secret-never-logged invariant
  structurally, `internal/enablement` provider dispatch, `internal/targeting`
  cross-account resolution, cobra `cmd/`. Per-tool `.golangci.yml` (Uber set
  minus the unconfigured root `goheader`). Quality gates:
  `go build/vet/test`, `golangci-lint run`, `govulncheck ./...`,
  `go-licenses check ./... --ignore github.com/donaldgifford/libtftest-tf-modules`
  (the `--ignore` skips the tool's own unlicensed packages; third-party deps
  are all Apache/MIT/BSD). The Go pin in `mise.toml` was bumped 1.26.2 →
  1.26.4 in this work to clear 4 call-reachable Go-stdlib CVEs (net/http,
  crypto/x509, net, net/textproto) surfaced via the AWS SDK HTTP transport.
  NB: after a Go bump, run `mise install go@<pin>` so the active binary
  matches the `go.mod` directive — otherwise `GOTOOLCHAIN=auto` resolves
  stdlib via a toolchain *module* and `go-licenses` fails on `syscall`/
  `os/signal`. Tests: mocks live in `internal/awsapi/mock_*.go` +
  `internal/sink/mock_sink.go` (exported, shared across test packages);
  the thin SDK-wrapper methods are unit-tested via a smithy Finalize
  middleware stub (`sdk_test.go`) that short-circuits before the HTTP
  send, so no LocalStack is needed. Coverage is measured with
  `go test -coverpkg=./... ./...` (~88% aggregate; every logic package
  ≥80%; only `Execute`/`main` bootstrap are uncovered).
  Subcommands: `mint` (Phase 13), `rotate` (Phase 14), `revoke`
  (Phase 15), `enable-models` (Phases 16-17, Paths A+B+C). `rotate` is the
  two-key zero-downtime handoff — it mints +
  verifies + writes the new secret to the sink *before* touching the old
  credential (so a failed verify rolls the new key back and leaves the old one
  Active), then deactivates → grace-sleeps → deletes the old. Verification uses
  a bearer-token Bedrock client (`awsapi.NewBedrockClientWithToken`, smithy
  `StaticTokenProvider`) built from the new credential, gated behind
  `--verify-profile`. `revoke` targets a credential by ID: deactivate → delete
  from IAM → (optional `--sink`) purge the secret, IAM-before-sink so a revoked
  key never lingers valid for an in-flight request; `--force` skips the
  confirmation prompt for CI. `enable-models` dispatches per-provider via
  `internal/enablement`: Path A (anthropic) submits the one-time use-case form
  (`PutUseCaseForModelAccess`, idempotent — the SDK `ConflictException` is
  translated to the `awsapi.ErrUseCaseAlreadyExists` domain sentinel so
  enablement stays SDK-error-free), Path B (amazon) is a no-op, Path C
  (meta/mistral/cohere/ai21/stability/openai marketplace) tries an explicit
  subscribe then falls back to a no-op InvokeModel trigger
  (`--marketplace-subscribe-path auto|explicit|invocation`, default auto). AWS
  has no callable subscribe API for Bedrock catalog entries, so the real
  `MarketplaceClient.Subscribe` returns `ErrSubscribeUnsupported` and the
  invocation trigger is the working path; a `ValidationException` from the
  generic trigger body is translated to `ErrModelInputRejected` and read as
  proof of access (past the subscribe gate). Cross-account `--target-accounts`
  (Phase 18, `internal/targeting`) resolves three modes: `current` and
  `org-management` run in the ambient account with no AssumeRole (org-management
  flags non-Anthropic providers with a warning row since only Anthropic's form
  cascades to members), `<account-id-list>` AssumeRoles (`--assume-role-name`,
  default `bedrock-enablement`) into each 12-digit account and swaps the client
  credentials per target. Results print as a per-account tab-aligned
  MODEL|PROVIDER|ACTION|OUTCOME table.

### Policy-as-code (`policy/`)

The fleet's conftest/OPA (Rego v1) policies, enforced repo-wide by the
static gate (`scripts/static-check.sh` §6) and standalone via `just
conftest`. `credentials.rego` (IMPL-0019 Phase 4 / DESIGN-0020) is the
generalized no-leak invariant: **no module may pass a credential through a
persisted Terraform argument** — deny rules on `secret_string` /
`secret_binary` (`aws_secretsmanager_secret_version`), `password`
(`aws_db_instance`), `master_password` (`aws_rds_cluster`); the write-only
`_wo` forms + `manage_master_user_password` are the only legal credential
paths. Presence alone is the violation (literal, var, or data read — it
still lands in state). The sweep runs conftest's **hcl2 parser** over
`modules/**/*.tf` (fixtures included); the parsed input shape is
`input.resource.<type>.<name>` = **array** of bodies (probe with `conftest
parse --parser hcl2` before writing rules). Unit tests in
`credentials_test.rego` run via `conftest verify` (also gate §6). Two
gotchas: keep `conftest` LAST in any pipeline (an early sweep piped
through `tail` ate a real FAIL's exit code), and the Atlantis plan-JSON
variant of this policy family belongs to the **live repo** (tfplan JSON is
a different input shape). First real catch: `ecr/pull-through-cache`'s
placeholder seeding (see the ECR bullet above).

## Tooling

All tool versions are pinned in `mise.toml`. Bootstrap with `mise install`
before doing anything else — the Terraform, terraform-docs, tflint,
golangci-lint, docz, just, etc. binaries all come from mise.

**No `latest`, ever, and every pin carries a `# renovate:` annotation.**
`latest` makes mise list upstream versions over the network on every run
under a 20s per-tool ceiling; one such call timing out against
`proxy.golang.org` killed `mise install` mid-CI and failed the static gate
before it ran a single check. Exact pins skip version listing entirely and
keep CI and local machines on identical binaries. Renovate keeps them
current via the custom regex manager in `renovate.json` (mise's own manager
is disabled there) — **a pin with no annotation is invisible to Renovate and
silently rots**, so always add one. Two datasource traps live here: `go:`
tools need the *full module path* as `depName`
(`github.com/google/go-licenses`, not `google/go-licenses`), and a repo
whose tags aren't bare semver needs an
`extractVersion` packageRule (`golang/go` → `go1.26.5`, `jqlang/jq` →
`jq-1.8.2`).

## Common commands

`justfile` recipes (run `just` to list, `just --list` for the full menu):

- `just docs lint|fix|fmt` — markdownlint over `docs/**/*.md` and root `*.md`
- `just tf <action> <module>` — per-module Terraform ops. `<module>` is the path
  under `modules/` (e.g. `eks/cluster`). Actions:
  - `validate` — `terraform init -backend=false && terraform validate`
  - `fmt` — `terraform fmt -check -recursive`
  - `lint` — `tflint --init && tflint`
  - `docs` — `terraform-docs .` (regenerates `USAGE.md`)
  - `test` — plan-only `terraform test` over `tests/*.tftest.hcl`. No
    LocalStack, no env vars, ~1.2s.
  - `test-localstack` — opt-in `terraform test -test-directory=tests-localstack`
    with `AWS_ENDPOINT_URL`/key/secret/region env vars pre-wired. Requires a
    LocalStack Pro container on `:4566`. ~75s.
  - `test-localstack-pro` — opt-in `terraform test
    -test-directory=tests-localstack-pro` for Pro-only surfaces (e.g. RDS Proxy,
    IMPL-0010 Q7) whose apply must NOT run under the default `test-localstack`.
    Same env wiring; requires a LocalStack **Pro** container + token. Only
    `modules/rds/proxy` has a `tests-localstack-pro/` directory today.
  - `all` — runs validate + lint + fmt + test in order (local convenience;
    CI splits these — see `just static` below).
- `just static` — the repo-wide static gate (ADR-0019): `terraform fmt` +
  `validate` + `tflint` + `terraform-docs` + the `policy/` conftest credential
  gate across **every** module, failing on any violation or stale `USAGE.md`.
  Wraps `scripts/static-check.sh`; this is what the CI `static` job runs first,
  before any plan/apply. Regenerates `USAGE.md` lock-free (deterministic
  `~> 6.2` constraint form).
- `just conftest` — the credential no-leak policy gate standalone (fast loop):
  `conftest verify` over `policy/` unit tests, then the hcl2-parser sweep of
  `modules/**/*.tf` against `policy/credentials.rego`. Also runs inside
  `just static`.
- `just changed [base]` — preview the CI test matrix for HEAD vs `base` (default
  `origin/main`): which **changed** modules CI runs at the plan / community / pro
  tiers. Wraps `scripts/changed-modules.sh` (IMPL-0016 / ADR-0019) — emits the
  `{changed, community, pro}` JSON matrix the CI `detect` job feeds to
  `strategy.matrix`, with a human summary on stderr. Self-tested by
  `scripts/changed-modules.test.sh` (`CHANGED_FILES_OVERRIDE` seam, no network).

Direct invocation still works (and is what the recipes call under the hood):

- `terraform init && terraform validate` — validate a module
- `tflint --init && tflint` — lint a module (each module has its own
  `.tflint.hcl`)
- `terraform-docs .` — regenerate `USAGE.md` (terraform-docs is configured with
  `output.mode: inject` writing into `USAGE.md` between `<!-- BEGIN_TF_DOCS -->`
  markers)

There is **no Makefile and no Go code** at the repo root. As of IMPL-0016
(restructured by ADR-0019), `.github/workflows/ci.yml` is the real **Terraform
test-gating pipeline** (not the inherited Go-library boilerplate it used to be),
a linear gated DAG: **`static` → `detect` → `plan` → apply → `ci-gate`**. The
`static` job runs first and repo-wide — `scripts/static-check.sh` (`just static`)
runs `terraform fmt` + `validate` + `tflint` + `terraform-docs` across **every**
module and fails on any violation or stale `USAGE.md` (docs regenerated
**lock-free** → deterministic `~> 6.2` constraint form; `git diff` vs HEAD). No
test runs until it's green. Then `detect` (`scripts/changed-modules.sh`, now
emitting `{changed, community, pro}` all scoped to the change set) feeds a `plan`
matrix over **changed modules only** (plan-only `just tf test`), which the
`test-localstack` (changed ∩ Community, Pro service container) and
`test-localstack-pro` (changed ∩ RDS-quartet) apply tiers depend on — all
aggregated by a single `ci-gate` check (all-present-tiers-must-pass; ADR-0018 §
gate, ADR-0019 ordering). **Both apply tiers are gated by the repo-variable
toggle `CI_RUN_LOCALSTACK_APPLY` and are OFF by default** (IMPL-0016 Phase 6): the
LocalStack Pro `LOCALSTACK_AUTH_TOKEN` would not activate headless (a LocalStack
subscription issue external to the repo), so the tiers skip until the variable is
set to `'true'` (`gh variable set CI_RUN_LOCALSTACK_APPLY --body true`) — no code
change to flip. `ci-gate` tolerates the skipped tiers; the static + plan gates
stay enforced. PR auto-labeling moved to `.github/workflows/labeler.yml`;
`release.yml` keeps only `bump-version`; `security.yml`'s `govulncheck` is scoped
to the two real Go modules (`tools/bedrock-keyctl`, `modules/eks/cluster/test`).

## Documentation lifecycle

Project design docs are managed by
[docz](https://github.com/donaldgifford/docz), configured via `.docz.yaml`. Six
doc types are enabled (rfc / adr / design / impl / plan / investigation) and
land under `docs/<type>/`. Use the CLI:

- `docz create adr "Title"` / `docz create rfc "Title"` / etc.
- `docz update` — regenerates the README index tables
- `docz list` / `docz show <type>` — discovery

Don't hand-edit the README index tables; they're regenerated. MkDocs (TechDocs)
integration is configured in `.docz.yaml` under `wiki:` for downstream
publishing.
