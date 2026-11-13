#!/usr/bin/env bash
#
# EXAMPLE ONLY: not a supported interface, and CI in this repo does not
# run it. The INTAKE side: promote one quarantined image by digest, then
# sign it and attach a scan attestation with the KMS signing key.
#
# Written against crane 0.20.6 and cosign 3.1.1. In cosign 3.x the
# transparency-log upload is switched off with a signing config that
# lists no transparency-log services (signing-config.no-tlog.json); the
# older --tlog-upload=false flag still works there but is deprecated.
# Verifiers must then skip the log too (cosign verify
# --insecure-ignore-tlog=true, or the admission controller's
# equivalent).
#
# Needs: the intake role's intake_policy_json, AllowSign on the key
# (kms/signing-key signer_principal_arns), and an ECR login.
#
# Usage: REGISTRY=111111111111.dkr.ecr.us-east-1.amazonaws.com \
#        SIGNING_KEY_ARN=arn:aws:kms:us-east-1:111111111111:key/<id> \
#          ./promote.sh mirror/registry.k8s.io/ingress-nginx/controller v1.12.1 sha256:<digest>

set -euo pipefail

readonly REPOSITORY="${1:?usage: promote.sh <promoted-repository> <tag> <digest>}"
readonly TAG="${2:?tag required}"
readonly DIGEST="${3:?digest required}"
readonly REGISTRY="${REGISTRY:?set REGISTRY}"
readonly KEY="awskms:///${SIGNING_KEY_ARN:?set SIGNING_KEY_ARN (the key ARN: aliases do not resolve cross-account)}"
readonly QUARANTINE="${QUARANTINE_PREFIX:-quarantine}"
readonly SIGNING_CONFIG="${SIGNING_CONFIG:-$(dirname "$0")/signing-config.no-tlog.json}"

readonly SOURCE="${REGISTRY}/${QUARANTINE}/${REPOSITORY}"
readonly TARGET="${REGISTRY}/${REPOSITORY}"

main() {
  local repo_name="${QUARANTINE}/${REPOSITORY}"
  local scan

  # The scan gate. A real intake workflow applies its own policy; this
  # example refuses any CRITICAL finding from scan-on-push.
  aws ecr wait image-scan-complete \
    --repository-name "${repo_name}" --image-id "imageDigest=${DIGEST}"
  aws ecr describe-image-scan-findings \
    --repository-name "${repo_name}" --image-id "imageDigest=${DIGEST}" \
    --query 'imageScanFindings' --output json >scan.json
  if [[ "$(jq '.findingSeverityCounts.CRITICAL // 0' scan.json)" != "0" ]]; then
    echo "::error::${repo_name}@${DIGEST} has CRITICAL findings; not promoting" >&2
    exit 1
  fi

  # Promote by digest. The first push creates the repository from the
  # promoted creation template (immutable tags, intake-only writes).
  crane copy "${SOURCE}@${DIGEST}" "${TARGET}:${TAG}"

  # Sign, then attach the scan result. Both write sha256-* referrer
  # tags, which the promoted template's default exclusion keeps mutable.
  cosign sign --yes --key "${KEY}" --signing-config "${SIGNING_CONFIG}" \
    "${TARGET}@${DIGEST}"
  scan="$(mktemp)"
  jq '{scanner: "ecr-basic", findings: .findingSeverityCounts}' scan.json >"${scan}"
  cosign attest --yes --key "${KEY}" --signing-config "${SIGNING_CONFIG}" \
    --type https://example.com/scan/v1 --predicate "${scan}" \
    "${TARGET}@${DIGEST}"
  rm -f "${scan}" scan.json
}

main "$@"
