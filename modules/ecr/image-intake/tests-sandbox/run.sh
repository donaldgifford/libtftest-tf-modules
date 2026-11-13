#!/usr/bin/env bash
#
# Real-AWS sandbox runbook for modules/ecr/image-intake (IMPL-0027
# Phase 7, DESIGN-0031 § Testing Strategy). OPERATOR-RUN, never CI.
#
# Applies ecr/image-intake together with ecr/registry and
# kms/signing-key in a DEDICATED registry account, plus throwaway
# writer / intake / unrelated roles and an SQS queue for the event leg.
# The intake workflow is stood in for by the sbx-intake role driven
# from this script (IMPL-0027 OQ 5a).
#
#   REGISTRY_PROFILE  the registry account
#   CONSUMER_PROFILE  a second account (one throwaway IAM role)
#   OPERATOR_ARN      the IAM role ARN behind REGISTRY_PROFILE, WITH its
#                     path (aws iam get-role); it becomes the admin of
#                     the templates and the signing key
#
# Output: PASS / FAIL for assertions, RECORD for probes whose answer is
# the finding; also written to results.txt. Stops at the first FAIL;
# the EXIT trap tears down (the signing key and the CMK enter their
# deletion windows).
#
# Usage:
#   REGISTRY_PROFILE=sbx-registry CONSUMER_PROFILE=sbx-consumer \
#   OPERATOR_ARN=arn:aws:iam::<acct>:role/<path>/<name> REGION=us-east-1 ./run.sh
#
# Needs: terraform >= 1.9, aws cli v2, crane, cosign 3.x, jq, and
# mikefarah yq 4 (for the examples leg).

set -euo pipefail

readonly REGISTRY_PROFILE="${REGISTRY_PROFILE:?set REGISTRY_PROFILE}"
readonly CONSUMER_PROFILE="${CONSUMER_PROFILE:?set CONSUMER_PROFILE}"
readonly OPERATOR_ARN="${OPERATOR_ARN:?set OPERATOR_ARN (the registry-side role ARN, with path)}"
readonly REGION="${REGION:-us-east-1}"
readonly UPSTREAM="${UPSTREAM:-public.ecr.aws/docker/library/alpine:3.20}"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MODULE_DIR
readonly MODULES_ROOT="${MODULE_DIR}/../.."
readonly RESULTS="${PWD}/results.txt"
WORKDIR="$(mktemp -d)"
readonly WORKDIR

REGISTRY_ACCOUNT=""
CONSUMER_ACCOUNT=""
HOST=""
DIGEST=""
QUEUE_URL=""
KEY_ARN=""

log() { echo "$*" | tee -a "${RESULTS}"; }
pass() { log "PASS: $*"; }
fail() {
  log "FAIL: $*"
  exit 1
}
record() { log "RECORD: $*"; }

reg() { aws --profile "${REGISTRY_PROFILE}" --region "${REGION}" "$@"; }
settle() { sleep "${SETTLE_SECONDS:-15}"; }

# as_role <profile> <account> <role> <command...>: run a command as a
# role, in a subshell with its own docker config logged in to ECR.
as_role() {
  local profile="$1" account="$2" role="$3"
  shift 3
  (
    local creds
    creds="$(aws --profile "${profile}" sts assume-role \
      --role-arn "arn:aws:iam::${account}:role/${role}" \
      --role-session-name ecr-intake-sandbox --query Credentials --output json)"
    unset AWS_PROFILE
    AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"${creds}")"
    AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"${creds}")"
    AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"${creds}")"
    AWS_REGION="${REGION}"
    DOCKER_CONFIG="$(mktemp -d)"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION DOCKER_CONFIG
    aws ecr get-login-password | crane auth login "${HOST}" -u AWS --password-stdin >/dev/null 2>&1
    "$@"
  )
}

as_reg() {
  local role="$1"
  shift
  as_role "${REGISTRY_PROFILE}" "${REGISTRY_ACCOUNT}" "${role}" "$@"
}

as_consumer() { as_role "${CONSUMER_PROFILE}" "${CONSUMER_ACCOUNT}" sbx-consumer "$@"; }

expect_ok() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "${msg}"; else fail "${msg}"; fi
}

expect_denied() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then fail "${msg}"; else pass "${msg}"; fi
}

# record_result <label> <command...>: run, record success or the error.
record_result() {
  local label="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    record "${label}: SUCCEEDED"
  else
    record "${label}: FAILED: $(tail -1 <<<"${out}")"
  fi
}

pull() { crane export "$1" - >/dev/null; }

apply_stack() {
  # One retry: KMS can reject a key policy naming a role IAM created
  # seconds earlier ("invalid principal") until it propagates.
  terraform -chdir="${WORKDIR}/registry" apply -auto-approve -input=false "$@" >/dev/null ||
    { sleep 20 && terraform -chdir="${WORKDIR}/registry" apply -auto-approve -input=false "$@" >/dev/null; }
  settle
}

out() { terraform -chdir="${WORKDIR}/registry" output -raw "$1"; }

# Events whose repository-name starts with $1, from the intake queue.
count_events() {
  local prefix="$1" total=0 batch i
  for i in 1 2 3 4 5 6; do
    batch="$(reg sqs receive-message --queue-url "${QUEUE_URL}" \
      --max-number-of-messages 10 --wait-time-seconds 10 --output json)"
    total=$((total + $(jq --arg p "${prefix}" \
      '[.Messages[]?.Body | fromjson | select(.detail["repository-name"] | startswith($p))] | length' <<<"${batch}")))
    jq -r '.Messages[]?.ReceiptHandle' <<<"${batch}" | while read -r h; do
      reg sqs delete-message --queue-url "${QUEUE_URL}" --receipt-handle "${h}"
    done
    [[ "${i}" -ge 3 && "${total}" -gt 0 ]] && break
  done
  echo "${total}"
}

write_stacks() {
  mkdir -p "${WORKDIR}/registry" "${WORKDIR}/consumer"
  cp "${MODULE_DIR}/examples/signing-config.no-tlog.json" "${WORKDIR}/"

  cat >"${WORKDIR}/registry/main.tf" <<TF
provider "aws" {
  region  = "${REGION}"
  profile = "${REGISTRY_PROFILE}"
}

variable "use_cmk" {
  type    = bool
  default = false
}

locals {
  role_base = "arn:aws:iam::${REGISTRY_ACCOUNT}:role"
}

resource "aws_iam_role" "sbx" {
  for_each = toset(["sbx-writer", "sbx-intake", "sbx-unrelated"])

  name = each.key
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { AWS = "arn:aws:iam::${REGISTRY_ACCOUNT}:root" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "writer" {
  name   = "ecr-writer"
  role   = aws_iam_role.sbx["sbx-writer"].id
  policy = module.intake.writer_policy_json
}

resource "aws_iam_role_policy" "intake" {
  name   = "ecr-intake"
  role   = aws_iam_role.sbx["sbx-intake"].id
  policy = module.intake.intake_policy_json
}

# An unrelated same-account role with broad ECR rights: only the
# repository policies stand between it and quarantine / mirror.
resource "aws_iam_role_policy" "unrelated" {
  name = "ecr-everything"
  role = aws_iam_role.sbx["sbx-unrelated"].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "ecr:*", Resource = "*" }]
  })
}

# The encryption leg's bring-your-own key, with the DEFAULT key policy
# (INV-0012 P4 asks whether a cross-account pull works under it).
resource "aws_kms_key" "cmk" {
  count = var.use_cmk ? 1 : 0

  description             = "ecr image-intake sandbox repository key"
  deletion_window_in_days = 7
}

resource "aws_sqs_queue" "events" {
  name = "sbx-intake-events"
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = module.intake.intake_event_rule_arn } }
    }]
  })
}

module "intake" {
  source = "${MODULE_DIR}"

  name                  = "sbx-intake"
  writer_principal_arns = ["\${local.role_base}/sbx-writer"]
  intake_principal_arns = ["\${local.role_base}/sbx-intake"]
  admin_principal_arns  = ["${OPERATOR_ARN}"]

  # strict: an exclusion that matches nothing cosign writes, so the
  # cosign leg can ask whether ECR's referrers support makes the
  # sha256-* exclusion unnecessary (DESIGN-0031 OQ 6).
  promoted_prefixes = {
    mirror = {}
    strict = { tag_mutability_exclusions = ["no-match-*"] }
  }

  intake_event_target = { arn = aws_sqs_queue.events.arn }
  kms_key_arn         = var.use_cmk ? aws_kms_key.cmk[0].arn : null

  depends_on = [aws_iam_role.sbx]
}

module "registry" {
  source = "${MODULES_ROOT}/ecr/registry"

  consumer_accounts        = { "${CONSUMER_ACCOUNT}" = {} }
  pull_repository_prefixes = module.intake.promoted_prefixes

  scanning = {
    scan_type = "BASIC"
    rules     = [{ scan_frequency = "SCAN_ON_PUSH", filters = ["quarantine/*"] }]
  }
}

module "signing" {
  source = "${MODULES_ROOT}/kms/signing-key"

  name                  = "sbx-intake-signing"
  admin_principal_arns  = ["${OPERATOR_ARN}"]
  signer_principal_arns = ["\${local.role_base}/sbx-intake"]

  depends_on = [aws_iam_role.sbx]
}

output "queue_url" {
  value = aws_sqs_queue.events.url
}

output "key_arn" {
  value = module.signing.key_arn
}

output "consumer_identity_policy_json" {
  value = module.registry.consumer_identity_policy_json
}
TF

  cat >"${WORKDIR}/consumer/main.tf" <<TF
provider "aws" {
  region  = "${REGION}"
  profile = "${CONSUMER_PROFILE}"
}

variable "identity_policy_json" {
  type = string
}

resource "aws_iam_role" "consumer" {
  name = "sbx-consumer"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { AWS = "arn:aws:iam::${CONSUMER_ACCOUNT}:root" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "consumer" {
  name   = "ecr-consumer"
  role   = aws_iam_role.consumer.id
  policy = var.identity_policy_json
}
TF
}

cleanup() {
  set +e
  if [[ "${KEEP:-0}" == "1" ]]; then
    log "KEEP=1: leaving ${WORKDIR} and the stacks in place"
    return
  fi
  # Repositories are created by ECR on push, outside Terraform.
  reg ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null |
    tr '\t' '\n' | grep -E '^(quarantine|mirror|strict)/' | while read -r r; do
    reg ecr delete-repository --repository-name "${r}" --force >/dev/null 2>&1
  done
  terraform -chdir="${WORKDIR}/consumer" destroy -auto-approve -input=false \
    -var identity_policy_json='{}' >/dev/null 2>&1
  terraform -chdir="${WORKDIR}/registry" destroy -auto-approve -input=false >/dev/null 2>&1
  rm -rf "${WORKDIR}"
}

preflight() {
  if reg ecr get-registry-policy >/dev/null 2>&1 && [[ "${SANDBOX_FORCE:-0}" != "1" ]]; then
    fail "the registry already has a policy; use a dedicated sandbox account (or SANDBOX_FORCE=1)"
  fi
  if [[ -n "$(reg ecr describe-repository-creation-templates --query 'repositoryCreationTemplates[].prefix' --output text 2>/dev/null)" ]]; then
    fail "creation templates already exist in this registry; use a dedicated sandbox account"
  fi
  if reg ecr describe-repositories --query 'repositories[].repositoryName' --output text |
    tr '\t' '\n' | grep -qE '^(quarantine|mirror|strict)/'; then
    fail "repositories under quarantine/, mirror/ or strict/ already exist (templates only reach NEW repositories)"
  fi
}

leg_writer_and_services() {
  local q="${HOST}/quarantine/mirror/public.ecr.aws/docker/library/alpine"
  expect_ok "writer: push to quarantine (create-on-push)" as_reg sbx-writer crane copy "${UPSTREAM}" "${q}:sbx"
  expect_denied "writer: push to mirror denied" as_reg sbx-writer crane copy "${UPSTREAM}" "${HOST}/mirror/sbx/writer:sbx"

  expect_ok "services: scan-on-push completes in quarantine (the BoolIfExists exemption)" \
    reg ecr wait image-scan-complete --repository-name quarantine/mirror/public.ecr.aws/docker/library/alpine \
    --image-id "imageDigest=${DIGEST}"
  record "quarantine scan: $(reg ecr describe-image-scan-findings --repository-name quarantine/mirror/public.ecr.aws/docker/library/alpine \
    --image-id "imageDigest=${DIGEST}" --query '[imageScanStatus.status, imageScanFindings.findingSeverityCounts]' --output json | jq -c .)"
  expect_ok "lifecycle: the quarantine lifecycle policy is attached" \
    reg ecr get-lifecycle-policy --repository-name quarantine/mirror/public.ecr.aws/docker/library/alpine
  record "quarantine repo: $(reg ecr describe-repositories --repository-names quarantine/mirror/public.ecr.aws/docker/library/alpine \
    --query 'repositories[0].[imageTagMutability, encryptionConfiguration.encryptionType]' --output json | jq -c .)"

  local n
  n="$(count_events quarantine/)"
  if [[ "${n}" -ge 1 ]]; then pass "events: ${n} event(s) for the quarantine push"; else fail "events: no event for the quarantine push"; fi
}

leg_intake_and_isolation() {
  local q="${HOST}/quarantine/mirror/public.ecr.aws/docker/library/alpine"
  local m="${HOST}/mirror/public.ecr.aws/docker/library/alpine"
  expect_ok "intake: pull from quarantine" as_reg sbx-intake pull "${q}@${DIGEST}"
  expect_ok "intake: promote to mirror by digest" as_reg sbx-intake crane copy "${q}@${DIGEST}" "${m}:sbx"
  record "mirror repo: $(reg ecr describe-repositories --repository-names mirror/public.ecr.aws/docker/library/alpine \
    --query 'repositories[0].[imageTagMutability, imageTagMutabilityExclusionFilters]' --output json | jq -c .)"

  local n
  n="$(count_events mirror/)"
  if [[ "${n}" -eq 0 ]]; then pass "events: none for the mirror push"; else fail "events: ${n} event(s) for a mirror push"; fi

  expect_denied "isolation: unrelated ecr:* role refused on quarantine" as_reg sbx-unrelated pull "${q}@${DIGEST}"
  expect_denied "isolation: unrelated ecr:* role cannot push to mirror" \
    as_reg sbx-unrelated crane copy "${UPSTREAM}" "${HOST}/mirror/sbx/unrelated:sbx"
  expect_denied "isolation: consumer refused on quarantine" as_consumer pull "${q}@${DIGEST}"
  expect_ok "isolation: consumer pulls mirror" as_consumer pull "${m}@${DIGEST}"
}

leg_cosign() {
  local m="${HOST}/mirror/public.ecr.aws/docker/library/alpine"
  local s="${HOST}/strict/public.ecr.aws/docker/library/alpine"
  local key="awskms:///${KEY_ARN}" cfg="${WORKDIR}/signing-config.no-tlog.json"
  echo '{"scanner":"sandbox","result":"pass"}' >"${WORKDIR}/scan.json"

  expect_ok "cosign: sign mirror (sha256-* excluded)" \
    as_reg sbx-intake cosign sign --yes --key "${key}" --signing-config "${cfg}" "${m}@${DIGEST}"
  expect_ok "cosign: attest mirror (sha256-* excluded)" \
    as_reg sbx-intake cosign attest --yes --key "${key}" --signing-config "${cfg}" \
    --type https://example.com/scan/v1 --predicate "${WORKDIR}/scan.json" "${m}@${DIGEST}"
  record "mirror tags after sign+attest: $(as_reg sbx-intake crane ls "${m}" | tr '\n' ' ')"

  # OQ 6: with no matching exclusion, is a second referrer still
  # writable (ECR serving OCI 1.1 referrers), or does the fallback tag
  # hit immutability?
  expect_ok "strict: promote" as_reg sbx-intake crane copy "${m}@${DIGEST}" "${s}:sbx"
  record_result "strict: sign (default mode)" \
    as_reg sbx-intake cosign sign --yes --key "${key}" --signing-config "${cfg}" "${s}@${DIGEST}"
  record_result "strict: attest (default mode)" \
    as_reg sbx-intake cosign attest --yes --key "${key}" --signing-config "${cfg}" \
    --type https://example.com/scan/v1 --predicate "${WORKDIR}/scan.json" "${s}@${DIGEST}"
  record_result "strict: attest (--registry-referrers-mode=oci-1-1)" \
    as_reg sbx-intake cosign attest --yes --key "${key}" --signing-config "${cfg}" \
    --registry-referrers-mode=oci-1-1 \
    --type https://example.com/scan/v1 --predicate "${WORKDIR}/scan.json" "${s}@${DIGEST}"
  record "strict tags: $(as_reg sbx-intake crane ls "${s}" | tr '\n' ' ')"

  # Re-push of an identical tag and digest to an immutable repository.
  # crane copy would skip it ("existing manifest"), so re-tag directly.
  record_result "re-push identical tag+digest to immutable mirror" \
    as_reg sbx-intake crane tag "${m}@${DIGEST}" sbx
}

leg_examples() {
  cat >"${WORKDIR}/manifest.yaml" <<YAML
images:
  - source: ${UPSTREAM%:*}
    tag: ${UPSTREAM##*:}
    digest: ${DIGEST}
YAML
  expect_ok "examples: sync-writer.sh as the writer" \
    as_reg sbx-writer env REGISTRY="${HOST}" "${MODULE_DIR}/examples/sync-writer.sh" "${WORKDIR}/manifest.yaml"
  expect_ok "examples: promote.sh as intake" \
    as_reg sbx-intake env REGISTRY="${HOST}" SIGNING_KEY_ARN="${KEY_ARN}" \
    SIGNING_CONFIG="${WORKDIR}/signing-config.no-tlog.json" \
    bash -c "cd '${WORKDIR}' && '${MODULE_DIR}/examples/promote.sh' \
      'mirror/${UPSTREAM%:*}' '${UPSTREAM##*:}' '${DIGEST}'"
}

leg_encryption() {
  apply_stack -var use_cmk=true
  local q="${HOST}/quarantine/mirror/sbx-kms/alpine" m="${HOST}/mirror/sbx-kms/alpine"
  expect_ok "kms: writer pushes to a CMK-encrypted quarantine repo" as_reg sbx-writer crane copy "${UPSTREAM}" "${q}:sbx"
  record_result "kms: intake promotes to a CMK-encrypted mirror repo" \
    as_reg sbx-intake crane copy "${q}@${DIGEST}" "${m}:sbx"
  record_result "kms: consumer pull under the key's DEFAULT policy (INV-0012 P4)" \
    as_consumer pull "${m}@${DIGEST}"
  record "kms repo: $(reg ecr describe-repositories --repository-names mirror/sbx-kms/alpine \
    --query 'repositories[0].encryptionConfiguration' --output json 2>&1 | jq -c . 2>/dev/null)"
}

main() {
  : >"${RESULTS}"
  REGISTRY_ACCOUNT="$(aws --profile "${REGISTRY_PROFILE}" sts get-caller-identity --query Account --output text)"
  CONSUMER_ACCOUNT="$(aws --profile "${CONSUMER_PROFILE}" sts get-caller-identity --query Account --output text)"
  HOST="${REGISTRY_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
  log "registry ${REGISTRY_ACCOUNT}, consumer ${CONSUMER_ACCOUNT}, region ${REGION}, $(date -u +%FT%TZ)"
  log "tools: $(terraform version | head -1), $(aws --version), crane $(crane version), $(cosign version 2>&1 | grep GitVersion)"

  preflight
  DIGEST="$(crane digest "${UPSTREAM}")"
  log "upstream ${UPSTREAM} = ${DIGEST}"

  trap cleanup EXIT
  write_stacks
  terraform -chdir="${WORKDIR}/registry" init -input=false >/dev/null
  terraform -chdir="${WORKDIR}/consumer" init -input=false >/dev/null
  apply_stack
  QUEUE_URL="$(out queue_url)"
  KEY_ARN="$(out key_arn)"
  terraform -chdir="${WORKDIR}/consumer" apply -auto-approve -input=false \
    -var identity_policy_json="$(out consumer_identity_policy_json)" >/dev/null
  settle

  leg_writer_and_services
  leg_intake_and_isolation
  leg_cosign
  leg_examples
  leg_encryption
  log "done"
}

main "$@"
