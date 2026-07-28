#!/usr/bin/env bash
#
# static-check.sh — repo-wide Terraform static gate (ADR-0019 / IMPL-0017).
#
# Runs the format / validate / lint / docs checks across EVERY module before any
# plan or apply test runs in CI. It is the first gate: nothing downstream (plan,
# LocalStack apply, Pro apply) executes until this passes, so no test burns time
# against a tree that is not formatted, valid, lint-clean, and doc-fresh.
#
# Checks:
#   1. terraform fmt -check -recursive   — repo-wide, one pass (covers fixtures)
#   2. terraform validate                — per module (terraform init -backend=false)
#   3. tflint                            — per module (each module's .tflint.hcl)
#   4. terraform-docs                    — per module; regenerate USAGE.md, then
#                                          fail if it produced a diff (stale docs)
#
# Every category runs even if an earlier one failed, so a single run surfaces all
# problems; the script exits non-zero if any category was dirty.
#
# Usage:
#   scripts/static-check.sh
#
# Speed: TF_PLUGIN_CACHE_DIR is exported so `terraform init` downloads the AWS
# provider once and reuses it across modules. Export GITHUB_TOKEN so the
# `tflint --init` plugin fetch uses the authenticated GitHub API rate limit.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

# Share the provider cache so the (large) AWS provider is fetched once, not once
# per module.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${REPO_ROOT}/.tf-plugin-cache}"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

# List leaf module directories (relative to modules/), one per line, sorted.
# Mirrors scripts/changed-modules.sh:list_modules so the two stay in lockstep.
list_modules() {
  find "${REPO_ROOT}/modules" -name '*.tf' \
    -not -path '*/tests*/*' -not -path '*/fixtures/*' -print0 \
    | xargs -0 -n1 dirname \
    | sort -u \
    | sed "s#^${REPO_ROOT}/modules/##"
}

log() { printf '\n==> %s\n' "$*"; }

fail=0

# ── 1. Format (repo-wide, one recursive pass) ──────────────────────────────
log "terraform fmt -check -recursive (repo-wide)"
if ! terraform fmt -check -recursive; then
  echo "::error::terraform fmt found unformatted files — run: terraform fmt -recursive"
  fail=1
fi

# ── 2. Docs: regenerate USAGE.md LOCK-FREE, then fail on any diff ───────────
# terraform-docs' `lockfile: true` bakes in the *resolved* provider version when
# a .terraform.lock.hcl is present; locks are gitignored, so their presence
# (and the version they pin) varies by environment. Removing the lock before
# generating keeps the Requirements table at the version *constraint*
# (e.g. `~> 6.2`) — deterministic across CI and local runs. Do this BEFORE any
# validate/init below re-creates a lock.
while IFS= read -r m; do
  [[ -n "${m}" ]] || continue
  dir="${REPO_ROOT}/modules/${m}"
  rm -f "${dir}/.terraform.lock.hcl"
  log "terraform-docs → ${m}"
  if ! (cd "${dir}" && terraform-docs . >/dev/null); then
    echo "::error::terraform-docs failed — ${m}"
    fail=1
  fi
done < <(list_modules)

log "terraform-docs freshness (git diff vs HEAD on USAGE.md)"
# Compare the regenerated docs against the committed (HEAD) version, not the
# index — the index can carry stale staged content and is irrelevant to "do the
# docs match what's committed?". In CI the checkout's index == HEAD anyway.
if ! git diff --quiet HEAD -- '*USAGE.md'; then
  echo "::error::USAGE.md is stale — run 'just tf docs <module>' and commit. Stale files:"
  git --no-pager diff --name-only HEAD -- '*USAGE.md' >&2
  fail=1
fi

# ── 3-4. Per-module validate + tflint ──────────────────────────────────────
while IFS= read -r m; do
  [[ -n "${m}" ]] || continue
  dir="${REPO_ROOT}/modules/${m}"

  log "validate → ${m}"
  if ! (cd "${dir}" \
    && terraform init -backend=false -input=false >/dev/null \
    && terraform validate); then
    echo "::error::terraform validate failed — ${m}"
    fail=1
  fi

  log "tflint → ${m}"
  if ! (cd "${dir}" && tflint --init >/dev/null && tflint); then
    echo "::error::tflint failed — ${m}"
    fail=1
  fi
done < <(list_modules)

if [[ "${fail}" -ne 0 ]]; then
  echo "::error::static gate failed — fix the errors above before plan/apply runs"
  exit 1
fi
echo "static gate passed: fmt + validate + tflint + terraform-docs clean across all modules"
