#!/usr/bin/env bash
#
# changed-modules.test.sh — self-test for changed-modules.sh (IMPL-0016 Phase 1).
#
# Feeds synthetic diffs through the CHANGED_FILES_OVERRIDE seam and asserts the
# emitted matrix. Pure logic — no git state, no network, no LocalStack. Run:
#
#   scripts/changed-modules.test.sh          # exits non-zero on any failure
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SUT="${REPO_ROOT}/scripts/changed-modules.sh"

# Live counts, derived the same way the SUT does, so the test tracks the tree
# instead of hard-coding a module total that drifts.
all_count() {
  find "${REPO_ROOT}/modules" -name '*.tf' \
    -not -path '*/tests*/*' -not -path '*/fixtures/*' -print0 \
    | xargs -0 -n1 dirname | sort -u | wc -l | tr -d ' '
}
tier_count() {
  local tier="$1" n=0 d
  for d in "${REPO_ROOT}/modules"/*/*/; do
    [[ -d "${d}${tier}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}

ALL_COUNT="$(all_count)"
LS_COUNT="$(tier_count tests-localstack)"
PRO_COUNT="$(tier_count tests-localstack-pro)"
readonly ALL_COUNT LS_COUNT PRO_COUNT

PASS=0
FAIL=0

# run <files> -> emits the matrix JSON for a synthetic diff on stdout.
run() { CHANGED_FILES_OVERRIDE="$1" "${SUT}" 2>/dev/null; }

# assert_eq <desc> <expected> <actual>
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    printf 'ok   — %s\n' "${desc}"
    PASS=$((PASS + 1))
  else
    printf 'FAIL — %s\n       expected: %s\n       actual:   %s\n' \
      "${desc}" "${expected}" "${actual}"
    FAIL=$((FAIL + 1))
  fi
}

# ── Case 1: single plan-only module ────────────────────────────────────────
out="$(run 'modules/ecr/org-registry/main.tf')"
assert_eq "single module: changed = itself" \
  '["ecr/org-registry"]' "$(jq -c '.changed' <<<"${out}")"
assert_eq "single module: community = itself" \
  '["ecr/org-registry"]' "$(jq -c '.community' <<<"${out}")"
assert_eq "single non-pro module: pro empty" \
  '[]' "$(jq -c '.pro' <<<"${out}")"

# ── Case 2: an RDS Pro module ──────────────────────────────────────────────
out="$(run 'modules/rds/cluster/variables.tf')"
assert_eq "pro module: community = itself" \
  '["rds/cluster"]' "$(jq -c '.community' <<<"${out}")"
assert_eq "pro module: pro = itself" \
  '["rds/cluster"]' "$(jq -c '.pro' <<<"${out}")"

# ── Case 3: reference-vpc fan-out -> its consumers ─────────────────────────
out="$(run 'test/fixtures/reference-vpc/main.tf')"
assert_eq "reference-vpc fan-out: changed = 5 RDS consumers" \
  '["rds/cluster","rds/instance","rds/proxy","rds/read-replica","rds/serverless"]' \
  "$(jq -c '.changed' <<<"${out}")"
assert_eq "reference-vpc fan-out: community = 5 RDS consumers" \
  '["rds/cluster","rds/instance","rds/proxy","rds/read-replica","rds/serverless"]' \
  "$(jq -c '.community' <<<"${out}")"
assert_eq "reference-vpc fan-out: pro = 4 RDS quartet" \
  '["rds/cluster","rds/instance","rds/proxy","rds/read-replica"]' \
  "$(jq -c '.pro' <<<"${out}")"

# ── Case 4: global fan-out (mise.toml) -> all modules ──────────────────────
out="$(run 'mise.toml')"
assert_eq "mise.toml: changed = all" \
  "${ALL_COUNT}" "$(jq -r '.changed | length' <<<"${out}")"
assert_eq "mise.toml: community = all with tests-localstack" \
  "${LS_COUNT}" "$(jq -r '.community | length' <<<"${out}")"
assert_eq "mise.toml: pro = all with tests-localstack-pro" \
  "${PRO_COUNT}" "$(jq -r '.pro | length' <<<"${out}")"

# ── Case 5: global fan-out (.github/**) ────────────────────────────────────
out="$(run '.github/workflows/ci.yml')"
assert_eq ".github fan-out: community = all with tests-localstack" \
  "${LS_COUNT}" "$(jq -r '.community | length' <<<"${out}")"

# ── Case 6: global fan-out (shared var-file) ───────────────────────────────
out="$(run 'test/fixtures/terragrunt-inputs.tfvars')"
assert_eq "terragrunt-inputs.tfvars fan-out: community = all with tests-localstack" \
  "${LS_COUNT}" "$(jq -r '.community | length' <<<"${out}")"

# ── Case 7: docs-only diff -> nothing changed, empty everywhere ─────────────
out="$(run $'docs/impl/0016-x.md\nREADME.md')"
assert_eq "docs-only: changed empty" '[]' "$(jq -c '.changed' <<<"${out}")"
assert_eq "docs-only: community empty" '[]' "$(jq -c '.community' <<<"${out}")"
assert_eq "docs-only: pro empty" '[]' "$(jq -c '.pro' <<<"${out}")"

# ── Case 8: deleted / stray paths are ignored ──────────────────────────────
out="$(run $'modules/ghost/gone/main.tf\nsome/random/file.txt')"
assert_eq "stray paths: changed empty" '[]' "$(jq -c '.changed' <<<"${out}")"
assert_eq "stray paths: community empty" '[]' "$(jq -c '.community' <<<"${out}")"
assert_eq "stray paths: pro empty" '[]' "$(jq -c '.pro' <<<"${out}")"

# ── Case 9: empty diff -> empty apply tiers ────────────────────────────────
out="$(run '')"
assert_eq "empty diff: community empty" '[]' "$(jq -c '.community' <<<"${out}")"

# ── Case 10: internal-module fan-out -> the whole service (IMPL-0018) ──────
# Expected set is derived live (every s3/ leaf module) so the case tracks the
# tree as purpose modules land instead of hard-coding today's membership.
s3_expected="$(find "${REPO_ROOT}/modules/s3" -name '*.tf' \
  -not -path '*/tests*/*' -not -path '*/fixtures/*' -print0 \
  | xargs -0 -n1 dirname | sort -u \
  | sed "s#^${REPO_ROOT}/modules/##" | jq -Rnc '[inputs]')"
out="$(run 'modules/s3/internal/core/policy.tf')"
assert_eq "internal fan-out: changed = every s3 leaf module" \
  "${s3_expected}" "$(jq -c '.changed' <<<"${out}")"
assert_eq "internal fan-out: the core itself is included" \
  'true' "$(jq -c 'any(.changed[]; . == "s3/internal/core")' <<<"${out}")"

# ── Case 11: internal + unrelated module -> union ──────────────────────────
out="$(run $'modules/s3/internal/core/bucket.tf\nmodules/ecr/org-registry/main.tf')"
assert_eq "internal + direct: union includes the unrelated module" \
  'true' "$(jq -c 'any(.changed[]; . == "ecr/org-registry")' <<<"${out}")"
assert_eq "internal + direct: union includes the s3 members" \
  'true' "$(jq -c 'any(.changed[]; . == "s3/internal/core")' <<<"${out}")"

# ── Case 12: an internal file does NOT map via the depth-2 direct rule ─────
# (modules/s3/internal/core/x.tf would slug to "s3/internal", which is not a
# module — the fan-out rule, not the direct rule, must carry it.)
out="$(run 'modules/s3/internal/core/versions.tf')"
assert_eq "internal file: no stray s3/internal slug" \
  'false' "$(jq -c 'any(.changed[]; . == "s3/internal")' <<<"${out}")"

printf '\n%s passed, %s failed (%s modules; %s localstack; %s pro)\n' \
  "${PASS}" "${FAIL}" "${ALL_COUNT}" "${LS_COUNT}" "${PRO_COUNT}"
[[ "${FAIL}" -eq 0 ]]
