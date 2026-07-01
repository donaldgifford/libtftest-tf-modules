#!/usr/bin/env bash
#
# gen-readme.sh — regenerate the module inventory table in README.md.
#
# Scans modules/ and, for each leaf module, derives:
#   * Version    — the earliest git tag containing the module's most recent
#                  *code* commit (top-level *.tf only; test/doc commits do
#                  not bump it). "unreleased" if not yet in any tag.
#   * Impl       — the IMPL doc that references the module (auto-derived).
#   * Plan tests — count of tests/*.tftest.hcl (the plan-only gate).
#   * LocalStack — apply | plan-only | — (based on uncommented `command =
#                  apply` in tests-localstack/).
#   * Pro        — ✅ if a tests-localstack-pro/ suite exists.
#
# The generated Markdown table is injected between the marker comments
#   <!-- BEGIN_MODULE_TABLE --> ... <!-- END_MODULE_TABLE -->
# in README.md.
#
# Usage:
#   scripts/gen-readme.sh            # rewrite the table in place
#   scripts/gen-readme.sh --check    # fail (exit 1) if the table is stale
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly README="${REPO_ROOT}/README.md"
readonly BEGIN_MARKER='<!-- BEGIN_MODULE_TABLE -->'
readonly END_MARKER='<!-- END_MODULE_TABLE -->'

# List leaf module directories (relative to modules/), one per line.
list_modules() {
  find "${REPO_ROOT}/modules" -name '*.tf' \
    -not -path '*/tests*/*' -not -path '*/fixtures/*' -print0 \
    | xargs -0 -n1 dirname \
    | sort -u \
    | sed "s#^${REPO_ROOT}/modules/##"
}

# Earliest tag containing the module's latest top-level *.tf commit.
module_version() {
  local mdir="$1"
  local -a tf_files=()
  while IFS= read -r f; do tf_files+=("$f"); done \
    < <(find "${mdir}" -maxdepth 1 -name '*.tf')
  if [[ ${#tf_files[@]} -eq 0 ]]; then
    printf '—'
    return
  fi
  local last_commit
  last_commit="$(git -C "${REPO_ROOT}" log -1 --format=%H -- "${tf_files[@]}")"
  if [[ -z "${last_commit}" ]]; then
    printf 'unreleased'
    return
  fi
  local tag
  tag="$(git -C "${REPO_ROOT}" tag --contains "${last_commit}" \
    --sort=v:refname 2>/dev/null | head -n1)"
  printf '%s' "${tag:-unreleased}"
}

# The IMPL doc id that references modules/<rel>, or "—".
module_impl() {
  local rel="$1"
  local file
  file="$(grep -rlE "modules/${rel}([^A-Za-z0-9_/-]|/|$)" \
    "${REPO_ROOT}/docs/impl/"*.md 2>/dev/null \
    | sed -E 's#.*/([0-9]{4})-.*#\1#' | sort -u | head -n1)"
  if [[ -n "${file}" ]]; then
    printf 'IMPL-%s' "${file}"
  else
    printf '—'
  fi
}

# Count of plan-only test files in tests/.
plan_count() {
  local mdir="$1"
  find "${mdir}/tests" -maxdepth 1 -name '*.tftest.hcl' 2>/dev/null | wc -l \
    | tr -d ' '
}

# LocalStack coverage label: apply | plan-only | —.
localstack_kind() {
  local mdir="$1"
  [[ -d "${mdir}/tests-localstack" ]] || { printf '—'; return; }
  if grep -qhE '^[[:space:]]*command[[:space:]]*=[[:space:]]*apply' \
    "${mdir}"/tests-localstack/*.tftest.hcl 2>/dev/null; then
    printf 'apply'
  else
    printf 'plan-only'
  fi
}

# Build the Markdown table on stdout.
render_table() {
  printf '| Module | Version | Impl | Plan tests | LocalStack | Pro |\n'
  printf '|--------|---------|------|:----------:|:----------:|:---:|\n'
  local rel mdir version impl plan ls pro
  while IFS= read -r rel; do
    mdir="${REPO_ROOT}/modules/${rel}"
    version="$(module_version "${mdir}")"
    impl="$(module_impl "${rel}")"
    plan="$(plan_count "${mdir}")"
    ls="$(localstack_kind "${mdir}")"
    [[ -d "${mdir}/tests-localstack-pro" ]] && pro='✅' || pro='—'
    # Backticks below are literal Markdown, not command substitution.
    # shellcheck disable=SC2016
    printf '| [`%s`](modules/%s) | `%s` | %s | %s | %s | %s |\n' \
      "${rel}" "${rel}" "${version}" "${impl}" "${plan}" "${ls}" "${pro}"
  done < <(list_modules)
}

# Rewrite README with a freshly rendered table between the markers.
# Emits the new file content on stdout.
splice_readme() {
  local table_file="$1"
  awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" -v tf="${table_file}" '
    index($0, begin) {
      print
      print ""
      while ((getline line < tf) > 0) print line
      print ""
      skip = 1
      next
    }
    index($0, end) { print; skip = 0; next }
    !skip { print }
  ' "${README}"
}

main() {
  local check=0
  [[ "${1:-}" == "--check" ]] && check=1

  if ! grep -qF "${BEGIN_MARKER}" "${README}" \
    || ! grep -qF "${END_MARKER}" "${README}"; then
    echo "error: README.md is missing the ${BEGIN_MARKER} / ${END_MARKER} markers" >&2
    exit 2
  fi

  local table_file new_file
  table_file="$(mktemp)"
  new_file="$(mktemp)"
  trap 'rm -f "${table_file:-}" "${new_file:-}"' EXIT

  render_table > "${table_file}"
  splice_readme "${table_file}" > "${new_file}"

  if [[ "${check}" -eq 1 ]]; then
    if ! diff -q "${README}" "${new_file}" >/dev/null; then
      echo "error: README.md module table is stale — run 'just readme'" >&2
      diff -u "${README}" "${new_file}" || true
      exit 1
    fi
    echo "README.md module table is up to date."
    return
  fi

  cp "${new_file}" "${README}"
  echo "Regenerated the module table in README.md ($(list_modules | wc -l | tr -d ' ') modules)."
}

main "$@"
