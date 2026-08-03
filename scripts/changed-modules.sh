#!/usr/bin/env bash
#
# changed-modules.sh — map a git diff to the CI test matrix (IMPL-0016 / ADR-0018).
#
# Given a base ref, computes which leaf modules a change set touches and emits
# the changed-module CI matrix tiers as a JSON object on stdout:
#
#   {
#     "changed":   [ <changed modules — the plan tier> ],
#     "community": [ <changed ∩ has tests-localstack/> ],
#     "pro":       [ <changed ∩ has tests-localstack-pro/> ]
#   }
#
# All three are scoped to the CHANGED set: under ADR-0019 the repo-wide gate is
# the static job (fmt/validate/tflint/terraform-docs across everything, run
# first), so plan / apply only need to cover what changed.
#
# "Changed" = every leaf module with a touched file under
# modules/<service>/<name>/**, plus fan-out (INV-0006 Q3a / ADR-0018 §2):
#
#   * A change to justfile, mise.toml, .github/**, or the shared
#     test/fixtures/terragrunt-inputs.tfvars fans out to ALL modules
#     (toolchain / CI / fleet-wide test input — global blast radius).
#   * A change to a shared fixture dir (test/fixtures/<name>/**) fans out to
#     that fixture's CONSUMERS — the modules whose tree references <name>
#     (e.g. reference-vpc -> its remote-state consumers), computed by grep.
#   * A change to a service's internal module (modules/<service>/internal/**)
#     fans out to EVERY leaf module of that service (IMPL-0018) — an internal
#     core is consumed by relative path, so each consumer's plan composes it
#     and must re-test; the internal module itself is included (own plan suite).
#
# `community` / `pro` are the changed set intersected with the modules that
# actually ship that apply tier.
#
# A human-readable summary is written to stderr; stdout is pure JSON so the CI
# `detect` job can `jq` it straight into $GITHUB_OUTPUT.
#
# Usage:
#   scripts/changed-modules.sh [BASE_REF]      # default BASE_REF=origin/main
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly BASE_REF="${1:-origin/main}"

# The RDS quartet is the only Pro-apply tier today, but membership is derived
# from the presence of a tests-localstack-pro/ dir, not hard-coded.

# List leaf module directories (relative to modules/), one per line, sorted.
# Mirrors scripts/gen-readme.sh:list_modules so the two stay in lockstep.
list_modules() {
  find "${REPO_ROOT}/modules" -name '*.tf' \
    -not -path '*/tests*/*' -not -path '*/fixtures/*' -print0 \
    | xargs -0 -n1 dirname \
    | sort -u \
    | sed "s#^${REPO_ROOT}/modules/##"
}

# Files changed between BASE_REF and HEAD, repo-relative, one per line.
# Three-dot (merge-base) diff matches pull_request semantics; fall back to a
# two-dot diff if there is no common ancestor, and to empty on any git error.
#
# Testing seam: if CHANGED_FILES_OVERRIDE is set (even to empty), its value is
# used verbatim instead of consulting git — this lets changed-modules.test.sh
# feed synthetic diffs with no repo state, network, or LocalStack.
changed_files() {
  if [[ -n "${CHANGED_FILES_OVERRIDE+set}" ]]; then
    printf '%s' "${CHANGED_FILES_OVERRIDE}"
    return
  fi
  git -C "${REPO_ROOT}" diff --name-only "${BASE_REF}...HEAD" 2>/dev/null \
    || git -C "${REPO_ROOT}" diff --name-only "${BASE_REF}" 2>/dev/null \
    || true
}

# Leaf modules that ship a given test tier (tests-localstack | tests-localstack-pro),
# one per line. $1 = newline-delimited module list, $2 = tier dir name.
modules_with_tier() {
  local modules="$1" tier="$2" rel
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    [[ -d "${REPO_ROOT}/modules/${rel}/${tier}" ]] && printf '%s\n' "${rel}"
  done <<<"${modules}"
}

# Modules that reference a shared fixture (its consumers), one per line.
# $1 = fixture dir name under test/fixtures/ (e.g. reference-vpc).
fixture_consumers() {
  local fixture="$1"
  grep -rlE "fixtures/${fixture}([^A-Za-z0-9_-]|$)" "${REPO_ROOT}/modules" 2>/dev/null \
    | sed -E "s#^${REPO_ROOT}/modules/([^/]+/[^/]+)/.*#\1#" \
    | sort -u \
    || true
}

# Lines of $2 that also appear in $1 (set intersection; both newline-delimited).
# Output preserves $2's order. Empty inputs yield empty output.
intersect() {
  printf '%s\n' "$2" | grep -Fxf <(printf '%s\n' "$1") || true
}

# Compact the newline-delimited lists into the CI matrix JSON object.
emit_json() {
  local changed="$1" community="$2" pro="$3"
  jq -nc \
    --arg changed "${changed}" \
    --arg community "${community}" \
    --arg pro "${pro}" \
    '{
       changed:   ($changed   | split("\n") | map(select(length > 0)) | unique),
       community: ($community | split("\n") | map(select(length > 0)) | unique),
       pro:       ($pro       | split("\n") | map(select(length > 0)) | unique)
     }'
}

main() {
  local all_modules files
  all_modules="$(list_modules)"
  files="$(changed_files)"

  # Build the changed-module set (newline-delimited).
  local changed=""

  # Global fan-out: any toolchain / CI / fleet-wide-test-input change touches all.
  if printf '%s\n' "${files}" \
    | grep -qE '^(justfile|mise\.toml|test/fixtures/terragrunt-inputs\.tfvars)$|^\.github/'; then
    changed="${all_modules}"
  else
    # Direct module changes: modules/<service>/<name>/** -> <service>/<name>.
    local direct
    direct="$(printf '%s\n' "${files}" \
      | sed -nE 's#^modules/([^/]+/[^/]+)/.*#\1#p' | sort -u)"
    # Keep only slugs that are real modules (drops deletions / stray paths).
    changed="$(intersect "${all_modules}" "${direct}")"

    # Shared-fixture fan-out: test/fixtures/<name>/** -> that fixture's consumers.
    local fixtures name consumers
    fixtures="$(printf '%s\n' "${files}" \
      | sed -nE 's#^test/fixtures/([^/]+)/.*#\1#p' | sort -u)"
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      consumers="$(fixture_consumers "${name}")"
      changed="$(printf '%s\n%s\n' "${changed}" "${consumers}")"
    done <<<"${fixtures}"

    # Internal-module fan-out (IMPL-0018): modules/<service>/internal/** is a
    # shared core consumed by relative path — a change there re-tests every
    # leaf module of the service, the internal module itself included (it
    # ships its own plan suite).
    local internal_services svc members
    internal_services="$(printf '%s\n' "${files}" \
      | sed -nE 's#^modules/([^/]+)/internal/.*#\1#p' | sort -u)"
    while IFS= read -r svc; do
      [[ -n "${svc}" ]] || continue
      members="$(printf '%s\n' "${all_modules}" | grep -E "^${svc}/" || true)"
      changed="$(printf '%s\n%s\n' "${changed}" "${members}")"
    done <<<"${internal_services}"
  fi

  # Normalize the changed set: drop blanks, de-dup, keep only real modules.
  changed="$(intersect "${all_modules}" "${changed}")"

  # Derive the apply tiers from the changed set.
  local community pro
  community="$(intersect "${changed}" "$(modules_with_tier "${all_modules}" tests-localstack)")"
  pro="$(intersect "${changed}" "$(modules_with_tier "${all_modules}" tests-localstack-pro)")"

  # Human-readable summary to stderr.
  {
    echo "changed-modules (base: ${BASE_REF})"
    printf '  inventory        : %s modules\n' "$(count_lines "${all_modules}")"
    printf '  changed (plan)   : %s\n' "$(oneline "${changed}")"
    printf '  community apply  : %s\n' "$(oneline "${community}")"
    printf '  pro apply        : %s\n' "$(oneline "${pro}")"
  } >&2

  emit_json "${changed}" "${community}" "${pro}"
}

# Count non-empty lines in a newline-delimited string.
count_lines() {
  printf '%s\n' "$1" | grep -c '^..*$' || true
}

# Render a newline-delimited list as a space-joined one-liner (or "none").
oneline() {
  local joined
  joined="$(printf '%s\n' "$1" | grep -v '^$' | paste -sd' ' -)"
  printf '%s' "${joined:-none}"
}

main "$@"
