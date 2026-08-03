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
- **`modules/ecr/`** — `pull-through-cache` (IMPL-0005, implemented; previously
  lived at `modules/eks/ecr-pull-through-cache` and was relocated when
  DESIGN-0006 surfaced a second ECR module). `org-registry` (IMPL-0006,
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
- **`modules/s3/`** — the S3 bucket family (INV-0009 → DESIGN-0019 →
  IMPL-0018, in progress). Architecture: thin purpose modules over one shared
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
  run and passing). Remaining: `bucket` (Phase 3 — tri-state
  `access_logging`, first count-gated remote-state read), `events-bucket`
  (Phase 4); `cloudfront-origin-bucket` + `presigned-transfer-bucket`
  deferred.

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

## Tooling

All tool versions are pinned in `mise.toml`. Bootstrap with `mise install`
before doing anything else — the Terraform, terraform-docs, tflint,
golangci-lint, docz, just, etc. binaries all come from mise.

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
  `validate` + `tflint` + `terraform-docs` across **every** module, failing on any
  violation or stale `USAGE.md`. Wraps `scripts/static-check.sh`; this is what the
  CI `static` job runs first, before any plan/apply. Regenerates `USAGE.md`
  lock-free (deterministic `~> 6.2` constraint form).
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
