# justfile — IaC and developer-convenience workflows
# Run `just` for the menu, `just --list` to see everything.
set shell := ["bash", "-euo", "pipefail", "-c"]

# Shared Terragrunt-provided test inputs passed to every `terraform test`
# (IMPL-0015). Centralizes the six globals Terragrunt injects in production
# (account_name/account_id/region/remote_state_bucket/remote_state_bucket_region/
# deploy_role_name) so each consumer's account-scoped remote-state read +
# assume_role resolves. Absolute (IMPL-0018 task 1.1): a module-relative path
# breaks for module dirs deeper than modules/<service>/<module> (e.g. the
# depth-4 modules/s3/internal/core).
tf_test_varfile := justfile_directory() / "test/fixtures/terragrunt-inputs.tfvars"

# Show this menu.
default:
    @just --list --unsorted

# ───── Private helpers ──────────────────────────────────────

[private]
_log message:
    @echo -e "\033[36m==> {{message}}\033[0m"

# ───── Docs ─────────────────────────────────────────────────
# For new ADRs/RFCs/etc., use the docz CLI directly:
#   docz create adr "Title"
#   docz create rfc "Title"
#   docz update          (regenerates README index tables)

# Docs: lint|fix|fmt  (markdownlint-cli2 over docs/**/*.md)
[group('docs')]
docs action:
    @just _docs-{{action}}

[private]
_docs-lint:
    @just _log "markdownlint → docs/**/*.md '*.md'"
    markdownlint-cli2 'docs/**/*.md' '*.md'
    @echo "✓ Documentation linting complete"

[private]
_docs-fix:
    @just _log "markdownlint --fix → docs/**/*.md"
    markdownlint-cli2 --config .markdownlint.yaml --fix 'docs/**/*.md'

[private]
_docs-fmt:
    @just _log "markdownlint --format → docs/**/*.md"
    markdownlint-cli2 --config .markdownlint.yaml --format 'docs/**/*.md'

# Regenerate the module inventory table in README.md (version + test
# coverage, auto-derived). Pass `--check` to fail on drift (CI use).
[group('docs')]
readme *args:
    @just _log "gen-readme {{args}}"
    ./scripts/gen-readme.sh {{args}}

# ───── Terraform (per-module) ───────────────────────────────
# Operates on modules/<module>/ — pass the path relative to modules/,
# e.g.  just tf test eks/cluster

# Terraform: fmt|validate|lint|docs|test|test-localstack
[group('tf')]
tf action module:
    @just _tf-{{action}} {{module}}

[private]
_tf-fmt module:
    @just _log "terraform fmt -check -recursive → modules/{{module}}"
    cd modules/{{module}} && terraform fmt -check -recursive

[private]
_tf-validate module:
    @just _log "terraform validate → modules/{{module}}"
    cd modules/{{module}} && terraform init -backend=false -input=false >/dev/null && terraform validate

[private]
_tf-lint module:
    @just _log "tflint → modules/{{module}}"
    cd modules/{{module}} && tflint --init && tflint

[private]
_tf-docs module:
    @just _log "terraform-docs → modules/{{module}}"
    cd modules/{{module}} && terraform-docs .

# Default plan-only test suite (tests/). No LocalStack, no env vars.
[private]
_tf-test module:
    @just _log "terraform test (plan-only) → modules/{{module}}"
    cd modules/{{module}} && terraform init -backend=false -input=false >/dev/null && terraform test -var-file={{tf_test_varfile}}

# Opt-in apply-against-LocalStack suite (tests-localstack/). Requires a
# running LocalStack Pro container on :4566. Wires the env vars the s3
# backend of data.terraform_remote_state needs (see RFC-0001 Finding #2
# in tests-localstack/apply_localstack.tftest.hcl).
[private]
_tf-test-localstack module:
    @just _log "terraform test (apply against LocalStack) → modules/{{module}}"
    cd modules/{{module}} && \
        terraform init -backend=false -input=false -test-directory=tests-localstack >/dev/null && \
        AWS_ENDPOINT_URL=http://localhost:4566 \
        AWS_ACCESS_KEY_ID=test \
        AWS_SECRET_ACCESS_KEY=test \
        AWS_REGION=us-east-1 \
        terraform test -test-directory=tests-localstack -var-file={{tf_test_varfile}}

# Opt-in LocalStack PRO apply suite (tests-localstack-pro/). OFF BY
# DEFAULT — for Pro-only surfaces (e.g. RDS Proxy, IMPL-0010 Q7) whose
# apply must NOT run under the default test-localstack recipe. Requires a
# running LocalStack Pro container on :4566 (a LOCALSTACK_AUTH_TOKEN in
# the environment). Only modules with a tests-localstack-pro/ directory
# support this action.
[private]
_tf-test-localstack-pro module:
    @just _log "terraform test (PRO apply against LocalStack) → modules/{{module}}"
    cd modules/{{module}} && \
        terraform init -backend=false -input=false -test-directory=tests-localstack-pro >/dev/null && \
        AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566 \
        AWS_ACCESS_KEY_ID=test \
        AWS_SECRET_ACCESS_KEY=test \
        AWS_REGION=us-east-1 \
        terraform test -test-directory=tests-localstack-pro -var-file={{tf_test_varfile}}

# Run validate + lint + fmt + test (plan-only) in order. Stops on first failure.
[private]
_tf-all module:
    @just tf validate {{module}}
    @just tf lint {{module}}
    @just tf fmt {{module}}
    @just tf test {{module}}

# terraform-docs freshness check for one module: regenerate USAGE.md, fail on diff.
[private]
_tf-docs-check module:
    @just _log "terraform-docs (check) → modules/{{module}}"
    cd modules/{{module}} && terraform-docs . >/dev/null && git diff --exit-code -- USAGE.md

# Repo-wide static gate (ADR-0019): terraform fmt + validate + tflint +
# terraform-docs + conftest credential policy across every module. This is
# what the CI `static` job runs first, before any plan/apply. Regenerates
# USAGE.md in place and fails if any module's docs were stale.
[group('tf')]
static:
    @just _log "static gate → fmt + validate + tflint + terraform-docs + conftest (all modules)"
    ./scripts/static-check.sh

# Credential no-leak policy gate (IMPL-0019 Phase 4 / DESIGN-0020): conftest
# policy unit tests, then the fleet-wide sweep of modules/**/*.tf with the
# hcl2 parser against policy/credentials.rego. Also runs inside `just static`
# (scripts/static-check.sh §6); this recipe is the fast standalone loop.
# NB: conftest must stay LAST in its pipeline — piping its output (e.g.
# through `tail`) eats the failure exit code.
[group('tf')]
conftest:
    @just _log "conftest → policy unit tests + persisted-credential sweep (modules/**/*.tf)"
    conftest verify --policy policy/
    find modules -name '*.tf' -not -path '*/.terraform/*' -print0 | xargs -0 conftest test --parser hcl2 --policy policy/ --quiet

# Wraps scripts/changed-modules.sh (IMPL-0016 / ADR-0019): JSON matrix to stdout,
# human summary to stderr. All three tiers (`changed`/`community`/`pro`) cover
# only changed modules — the repo-wide gate is `just static`. base defaults to
# origin/main.
# Preview the CI test matrix (changed/community/pro) for HEAD vs a base ref.
[group('tf')]
changed base="origin/main":
    @scripts/changed-modules.sh {{base}} | jq .

