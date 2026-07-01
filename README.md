# libtftest-tf-modules

A monorepo of **production-grade AWS Terraform modules**, each verified with
[libtftest](https://github.com/donaldgifford/libtftest) — LocalStack-backed
integration tests that apply the module against a real (emulated) AWS API rather
than just planning it.

## Why this repo exists

Most public Terraform modules are either untested or tested only at plan time.
The goal here is a fleet of **small, single-purpose, from-scratch modules**
(no `terraform-aws-modules/*` wrapping) that are:

- **Composed through remote state**, not deep input threading — cross-module
  data flows through S3-backed `terraform_remote_state` (the Gruntwork
  infrastructure-live pattern, [ADR-0001](docs/adr)).
- **AWS-API only** — Kubernetes-API objects go through Argo/Kustomize, never the
  `kubernetes`/`helm` Terraform providers.
- **Actually applied in tests** — every module ships a plan-only gate *and* a
  LocalStack apply suite, with each real-world gap written up in a per-module
  `FINDINGS.md` (the [RFC-0001](docs/rfc) gap-discovery method).
- **Documented by decision** — the design rationale lives in
  [`docs/`](docs/) as ADRs, RFCs, DESIGN, and IMPL docs managed with
  [docz](https://github.com/donaldgifford/docz).

## Modules

<!-- BEGIN_MODULE_TABLE -->

| Module | Version | Impl | Plan tests | LocalStack | Pro |
|--------|---------|------|:----------:|:----------:|:---:|
| [`bedrock/claude-code`](modules/bedrock/claude-code) | `v0.10.0` | IMPL-0009 | 7 | apply | — |
| [`ecr/org-registry`](modules/ecr/org-registry) | `v0.7.0` | IMPL-0006 | 8 | plan-only | — |
| [`ecr/pull-through-cache`](modules/ecr/pull-through-cache) | `v0.6.1` | IMPL-0005 | 7 | plan-only | — |
| [`efs/filesystem`](modules/efs/filesystem) | `v0.9.0` | IMPL-0008 | 9 | apply | — |
| [`eks/addons`](modules/eks/addons) | `v0.4.0` | IMPL-0003 | 4 | apply | — |
| [`eks/cluster`](modules/eks/cluster) | `v0.2.0` | IMPL-0001 | 3 | apply | — |
| [`eks/managed-node-group`](modules/eks/managed-node-group) | `v0.3.0` | IMPL-0002 | 3 | apply | — |
| [`eks/pod-identity-access`](modules/eks/pod-identity-access) | `v0.5.0` | IMPL-0004 | 4 | apply | — |
| [`rds/proxy`](modules/rds/proxy) | `v0.10.1` | IMPL-0010 | 5 | plan-only | ✅ |
| [`rds/serverless`](modules/rds/serverless) | `v0.10.1` | IMPL-0007 | 6 | apply | — |

<!-- END_MODULE_TABLE -->

**Legend** — **Version**: the release tag in which the module's code last
changed (`unreleased` = newer than the latest tag; per-module tags are a
planned direction, see
[DESIGN-0011](docs/design/0011-per-module-version-tagging-scheme.md)).
**Plan tests**: number of
plan-only `tests/*.tftest.hcl` files (the always-on gate). **LocalStack**:
`apply` = the `tests-localstack/` suite provisions real resources; `plan-only` =
apply is blocked by a documented upstream LocalStack gap (see the module's
`FINDINGS.md`). **Pro**: ✅ = has a Pro-only apply suite in
`tests-localstack-pro/`.

> This table is generated — run `just readme` to regenerate it (or
> `just readme --check` in CI to detect drift). Do not hand-edit between the
> markers.

## Quickstart

### Prerequisites

All tool versions are pinned in [`mise.toml`](mise.toml). Bootstrap once:

```bash
mise install   # terraform, terraform-docs, tflint, just, docz, ...
```

### Consuming a module

Pin a module by git ref (repo-wide tag today; see the versioning note above):

```hcl
module "eks_cluster" {
  source = "git::https://github.com/donaldgifford/libtftest-tf-modules.git//modules/eks/cluster?ref=v0.10.2"

  # ... module inputs (see the module's USAGE.md) ...
}
```

Each module directory has a generated `USAGE.md` with its full input/output
reference and a `README.md` with operator guidance.

### Developing a module

The [`justfile`](justfile) drives per-module workflows — `<module>` is the path
under `modules/` (e.g. `eks/cluster`, `rds/proxy`):

```bash
just tf validate rds/proxy   # terraform init -backend=false && validate
just tf lint     rds/proxy   # tflint
just tf fmt      rds/proxy   # terraform fmt -check -recursive
just tf docs     rds/proxy   # regenerate USAGE.md (terraform-docs)
just tf test     rds/proxy   # plan-only tests/  (no AWS, ~1s)
just tf all      rds/proxy   # validate + lint + fmt + test
```

## Testing tiers

| Tier | Directory | Recipe | Needs |
|------|-----------|--------|-------|
| **Plan-only gate** | `tests/` | `just tf test <m>` | nothing — no AWS, no LocalStack |
| **LocalStack apply** | `tests-localstack/` | `just tf test-localstack <m>` | LocalStack Pro on `:4566` |
| **LocalStack Pro apply** | `tests-localstack-pro/` | `just tf test-localstack-pro <m>` | LocalStack **Pro** (off by default) |

The LocalStack suites apply the module against an emulated AWS API. Where a
LocalStack gap blocks an apply, the `run` block is preserved as commented HCL
and the gap is documented in the module's `tests-localstack/FINDINGS.md` with
the exact 501/error and a re-run trigger.

> **macOS note.** RDS/Aurora apply suites boot a real embedded Postgres, which
> needs `/var/lib/localstack` on a Docker **named volume** — a macOS host bind
> mount (the `lstk` default) makes `initdb` fail on data-dir ownership. See
> `modules/rds/proxy/tests-localstack/FINDINGS.md`.

## Documentation

Design docs live under [`docs/`](docs/), managed by
[docz](https://github.com/donaldgifford/docz):

- [`docs/rfc/`](docs/rfc) — proposals (e.g. the module testing strategy)
- [`docs/adr/`](docs/adr) — architecture decisions
- [`docs/design/`](docs/design) — per-feature design
- [`docs/impl/`](docs/impl) — phase-tracked implementation
- [`docs/investigation/`](docs/investigation) — time-boxed research

Create with `docz create <type> "Title"`; regenerate the index tables with
`docz update`.

## Repository layout

```text
modules/<service>/<module>/   # the Terraform modules (+ tests/, USAGE.md, README.md)
docs/<type>/                  # docz-managed ADR / RFC / DESIGN / IMPL / INV
tools/                        # in-tree Go tooling (e.g. bedrock-keyctl)
scripts/                      # repo automation (e.g. gen-readme.sh)
justfile                      # developer-convenience recipes
mise.toml                     # pinned tool versions
```

## In-tree tooling

- [`tools/bedrock-keyctl/`](tools/bedrock-keyctl) — Go CLI that mints/rotates/
  revokes the IAM credential Claude Code consumes on Bedrock, and enables model
  access per provider (IMPL-0009).
