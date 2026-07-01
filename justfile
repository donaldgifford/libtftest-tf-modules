# justfile — IaC and developer-convenience workflows
# Run `just` for the menu, `just --list` to see everything.
set shell := ["bash", "-euo", "pipefail", "-c"]

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
    cd modules/{{module}} && terraform init -backend=false -input=false >/dev/null && terraform test

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
        terraform test -test-directory=tests-localstack

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
        AWS_ENDPOINT_URL=http://localhost:4566 \
        AWS_ACCESS_KEY_ID=test \
        AWS_SECRET_ACCESS_KEY=test \
        AWS_REGION=us-east-1 \
        terraform test -test-directory=tests-localstack-pro

# Run validate + lint + fmt + test (plan-only) in order. Stops on first failure.
[private]
_tf-all module:
    @just tf validate {{module}}
    @just tf lint {{module}}
    @just tf fmt {{module}}
    @just tf test {{module}}

