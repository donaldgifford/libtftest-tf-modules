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
  v2 for Postgres + MySQL per DESIGN-0007). Three siblings still to ship per
  DESIGN-0007 rollout: `instance` (single `aws_db_instance`), `cluster` (Aurora
  provisioned, single-writer default), `read-replica` (additional
  `aws_rds_cluster_instance`s composed via cluster module's remote state).
- **`modules/efs/`** — `filesystem` (IMPL-0008, implemented — the AWS-API
  companion to the EKS addons module's already-installed `aws-efs-csi-driver`
  per DESIGN-0008). The `filesystem/` sub-directory leaves room for future
  siblings (e.g. `modules/efs/replica/` if cross-region replication ever lands).

The design and decision rationale for the fleet lives in `docs/adr/`
(ADR-0001..0016), `docs/rfc/` (RFC-0001..0002), and `docs/design/`
(DESIGN-0001..0008).

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
