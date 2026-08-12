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

# ── 5. s3 family guards (DESIGN-0019 / IMPL-0018 Phase 5) ──────────────────
# Two invariants no other tool can see:
#
#   a) The internal core is consumed ONLY via the relative path
#      `source = "../internal/core"`. It is exempt from the
#      no-nested-modules rule precisely BECAUSE it rides each purpose
#      module's tag — a versioned source (registry name or git ref) would
#      break that and let a purpose module pin a stale core.
#   b) The shared security-baseline suite is byte-identical across the
#      modules that carry the full F2 baseline. access-logs-bucket is the
#      documented F3 variant (SSE-S3, no tri-state) and is deliberately
#      excluded.
log "s3 family guards (core source form + baseline-suite identity)"

# (a) any `source =` pointing at the core must be exactly the relative path.
bad_core_source="$(grep -rn --include='*.tf' -E '^[[:space:]]*source[[:space:]]*=.*internal/core' \
  "${REPO_ROOT}/modules/s3" | grep -v '"\.\./internal/core"' || true)"
if [[ -n "${bad_core_source}" ]]; then
  echo "::error::the s3 internal core must be consumed only via source = \"../internal/core\" (never a registry name or git ref — DESIGN-0019 nesting exemption). Offending lines:"
  printf '%s\n' "${bad_core_source}" >&2
  fail=1
fi

# (b) baseline-suite identity across the full-baseline modules.
baseline_ref="${REPO_ROOT}/modules/s3/bucket/tests/security_baseline.tftest.hcl"
for m in events-bucket; do
  other="${REPO_ROOT}/modules/s3/${m}/tests/security_baseline.tftest.hcl"
  if ! diff -q "${baseline_ref}" "${other}" >/dev/null 2>&1; then
    echo "::error::modules/s3/${m}/tests/security_baseline.tftest.hcl must stay byte-identical to s3/bucket's copy (DESIGN-0019 OQ 3a). Diff:"
    diff "${baseline_ref}" "${other}" >&2 || true
    fail=1
  fi
done

# ── 6. Credential no-leak policy (IMPL-0019 Phase 4 / DESIGN-0020) ─────────
# conftest denies persisted credential arguments across every module
# source file — secret_string/secret_binary on
# aws_secretsmanager_secret_version, password on aws_db_instance,
# master_password on aws_rds_cluster. The write-only (_wo) forms +
# manage_master_user_password are the only legal credential paths.
# Policy + its unit tests live under policy/. NB: keep conftest LAST in
# its pipeline — an earlier run piped through `tail` silently ate a
# real FAIL's exit code.
log "conftest verify (policy unit tests, policy/)"
if ! conftest verify --policy "${REPO_ROOT}/policy" >/dev/null; then
  echo "::error::conftest verify failed — the policy unit tests under policy/ are broken"
  fail=1
fi

log "conftest test (persisted-credential sweep, modules/**/*.tf)"
if ! find "${REPO_ROOT}/modules" -name '*.tf' -not -path '*/.terraform/*' -print0 \
  | xargs -0 conftest test --parser hcl2 --policy "${REPO_ROOT}/policy" --quiet; then
  echo "::error::a persisted credential argument was found — use the write-only (_wo) form (policy/credentials.rego)"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "::error::static gate failed — fix the errors above before plan/apply runs"
  exit 1
fi
echo "static gate passed: fmt + validate + tflint + terraform-docs + s3 guards + conftest policy clean across all modules"
