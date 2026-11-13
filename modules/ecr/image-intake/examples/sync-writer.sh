#!/usr/bin/env bash
#
# EXAMPLE ONLY: not a supported interface, and CI in this repo does not
# run it. The WRITER side of the intake flow: copy each manifest entry
# into the quarantine prefix, pinned by digest.
#
# Written against crane 0.20.6, cosign 3.1.1, helm 4.2 and mikefarah
# yq 4 (preinstalled on GitHub-hosted Ubuntu runners).
#
# Needs: ECR and upstream registry logins already done (crane, cosign
# and helm all read ~/.docker/config.json), and the writer role's
# writer_policy_json.
#
# Usage: REGISTRY=111111111111.dkr.ecr.us-east-1.amazonaws.com \
#          ./sync-writer.sh manifest.yaml

set -euo pipefail

readonly MANIFEST="${1:?usage: sync-writer.sh <manifest.yaml>}"
readonly REGISTRY="${REGISTRY:?set REGISTRY to <account>.dkr.ecr.<region>.amazonaws.com}"
readonly QUARANTINE="${QUARANTINE_PREFIX:-quarantine}/mirror"

# NOTE: sync_image and sync_chart run in an `|| ...` context, where bash
# DISABLES set -e for the whole function. Every step that must stop the
# entry therefore checks its own exit status explicitly.

failures=0

err() {
  echo "::error::$*" >&2
}

sync_image() {
  local i="$1"
  local src tag digest dst current
  src="$(yq -r ".images[${i}].source" "${MANIFEST}")"
  tag="$(yq -r ".images[${i}].tag" "${MANIFEST}")"
  digest="$(yq -r ".images[${i}].digest" "${MANIFEST}")"
  dst="${REGISTRY}/${QUARANTINE}/${src}"

  # 1. Drift check: the tag must still resolve to the pinned digest. A
  #    mismatch means upstream retagged it; a human decides, not the job.
  current="$(crane digest "${src}:${tag}")"
  if [[ "${current}" != "${digest}" ]]; then
    err "${src}:${tag} resolves to ${current}, manifest pins ${digest}"
    return 1
  fi

  # 2. Verify the upstream signature when the publisher signs.
  if yq -e ".images[${i}].verify" "${MANIFEST}" >/dev/null 2>&1; then
    if ! cosign verify "${src}@${digest}" \
      --certificate-identity-regexp "$(yq -r ".images[${i}].verify.certificate_identity_regexp" "${MANIFEST}")" \
      --certificate-oidc-issuer "$(yq -r ".images[${i}].verify.certificate_oidc_issuer" "${MANIFEST}")" \
      >/dev/null; then
      err "${src}@${digest}: upstream signature did not verify"
      return 1
    fi
  fi

  # 3. Copy by digest (every platform of a multi-arch index), unless
  #    quarantine already holds it. Checking first keeps the job
  #    idempotent whether or not ECR accepts an identical re-push.
  #    The first push to a new repository creates it from the
  #    quarantine creation template.
  if [[ "$(crane digest "${dst}:${tag}" 2>/dev/null || true)" == "${digest}" ]]; then
    echo "skip ${src}:${tag} (already in quarantine)"
  else
    crane copy "${src}@${digest}" "${dst}:${tag}" || return 1
  fi

  # 4. Carry upstream signatures and attestations alongside the image,
  #    so intake can re-verify them from quarantine.
  if yq -e ".images[${i}].verify" "${MANIFEST}" >/dev/null 2>&1; then
    cosign copy --only=sig,att --force "${src}@${digest}" "${dst}@${digest}" || return 1
  fi
}

sync_chart() {
  local i="$1"
  local repo name version sha256 host work
  repo="$(yq -r ".charts[${i}].repo" "${MANIFEST}")"
  name="$(yq -r ".charts[${i}].name" "${MANIFEST}")"
  version="$(yq -r ".charts[${i}].version" "${MANIFEST}")"
  sha256="$(yq -r ".charts[${i}].sha256" "${MANIFEST}")"
  host="${repo#https://}"
  host="${host%%/*}"
  work="$(mktemp -d)"

  # HTTPS chart repositories have no digest: pin the archive's sha256.
  if ! helm pull "${name}" --repo "${repo}" --version "${version}" --destination "${work}"; then
    rm -rf "${work}"
    return 1
  fi
  if ! echo "${sha256}  ${work}/${name}-${version}.tgz" | sha256sum --check --status; then
    err "${name}-${version}.tgz does not match the pinned sha256"
    rm -rf "${work}"
    return 1
  fi

  # helm appends the chart name: .../quarantine/mirror/<host>/<name>.
  local rc=0
  helm push "${work}/${name}-${version}.tgz" "oci://${REGISTRY}/${QUARANTINE}/${host}" || rc=$?
  rm -rf "${work}"
  return "${rc}"
}

main() {
  local i count
  count="$(yq '.images | length' "${MANIFEST}")"
  for ((i = 0; i < count; i++)); do
    sync_image "${i}" || failures=$((failures + 1))
  done

  count="$(yq '.charts // [] | length' "${MANIFEST}")"
  for ((i = 0; i < count; i++)); do
    sync_chart "${i}" || failures=$((failures + 1))
  done

  # One bad entry must not block the rest, but the run must fail.
  if ((failures > 0)); then
    err "${failures} manifest entries failed"
    exit 1
  fi
}

main "$@"
