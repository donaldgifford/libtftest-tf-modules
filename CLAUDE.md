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
  (see the module's `tests-localstack/FINDINGS.md`).
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

The design and decision rationale for the fleet lives in `docs/adr/`
(ADR-0001..0016), `docs/rfc/` (RFC-0001..0003), and `docs/design/`
(DESIGN-0001..0009).

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
  - `all` — runs validate + lint + fmt + test in order.

Direct invocation still works (and is what the recipes call under the hood):

- `terraform init && terraform validate` — validate a module
- `tflint --init && tflint` — lint a module (each module has its own
  `.tflint.hcl`)
- `terraform-docs .` — regenerate `USAGE.md` (terraform-docs is configured with
  `output.mode: inject` writing into `USAGE.md` between `<!-- BEGIN_TF_DOCS -->`
  markers)

There is **no Makefile and no Go code** at the repo root, despite the inherited
`.golangci.yml` and `.github/workflows/ci.yml` referencing both. See the "CI
caveat" section below.

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
