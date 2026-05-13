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

