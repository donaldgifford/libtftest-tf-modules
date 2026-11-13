#!/usr/bin/env bash
#
# Real-AWS sandbox runbook for modules/ecr/registry (IMPL-0027 Phase 7,
# DESIGN-0030 OQ 11a). OPERATOR-RUN, never CI. Two accounts:
#
#   REGISTRY_PROFILE  the registry account (a DEDICATED sandbox: this
#                     overwrites the registry policy, REGISTRY_POLICY_SCOPE
#                     and the scanning configuration, all per-registry
#                     singletons)
#   CONSUMER_PROFILE  the consumer account (two throwaway IAM roles)
#
# Legs (see README.md): P1 ordering from V1, P1 pull on V2, P1 the V1
# probe, P2 quarantine refused / mirror allowed, P2 with an over-broad
# pass-through, narrowing, destroy. P3 (a node not built by this repo)
# is a manual step in README.md.
#
# Output: PASS / FAIL lines for assertions, RECORD lines for probes whose
# answer is the finding. Everything is also written to results.txt. The
# script stops at the first FAIL, and the EXIT trap tears down.
#
# Usage:
#   REGISTRY_PROFILE=sbx-registry CONSUMER_PROFILE=sbx-consumer \
#   REGION=us-east-1 ./run.sh
#
# Needs: terraform >= 1.9, aws cli v2, crane, jq.

set -euo pipefail

readonly REGISTRY_PROFILE="${REGISTRY_PROFILE:?set REGISTRY_PROFILE}"
readonly CONSUMER_PROFILE="${CONSUMER_PROFILE:?set CONSUMER_PROFILE}"
readonly REGION="${REGION:-us-east-1}"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MODULE_DIR
readonly RESULTS="${PWD}/results.txt"
WORKDIR="$(mktemp -d)"
readonly WORKDIR

REGISTRY_ACCOUNT=""
CONSUMER_ACCOUNT=""
REGISTRY_HOST=""
CANARY_DIGEST=""

log() { echo "$*" | tee -a "${RESULTS}"; }
pass() { log "PASS: $*"; }
fail() {
  log "FAIL: $*"
  exit 1
}
record() { log "RECORD: $*"; }

reg() { aws --profile "${REGISTRY_PROFILE}" --region "${REGION}" "$@"; }

# Run a command as a role in the consumer account, with its own docker
# config, logged in to the registry. Runs in a subshell so nothing
# leaks into the caller's environment.
as_consumer_role() {
  local role="$1"
  shift
  (
    local creds
    creds="$(aws --profile "${CONSUMER_PROFILE}" sts assume-role \
      --role-arn "arn:aws:iam::${CONSUMER_ACCOUNT}:role/${role}" \
      --role-session-name ecr-registry-sandbox --query Credentials --output json)"
    unset AWS_PROFILE
    AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"${creds}")"
    AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"${creds}")"
    AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"${creds}")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    DOCKER_CONFIG="$(mktemp -d)"
    export DOCKER_CONFIG
    aws ecr get-login-password --region "${REGION}" |
      crane auth login "${REGISTRY_HOST}" -u AWS --password-stdin >/dev/null 2>&1
    "$@"
  )
}

# Pull the whole image (manifest + layer), so BatchGetImage and
# GetDownloadUrlForLayer are both exercised.
pull() { crane export "$1" - >/dev/null 2>&1; }

can_pull() { as_consumer_role "$1" pull "$2"; }

# Policy changes are eventually consistent; give them a moment.
settle() { sleep "${SETTLE_SECONDS:-15}"; }

expect_allowed() {
  if can_pull "$1" "$2"; then pass "$3"; else fail "$3"; fi
}

expect_refused() {
  if can_pull "$1" "$2"; then fail "$3"; else pass "$3"; fi
}

# crane as the operator (registry profile), with its own docker config.
op_crane() { DOCKER_CONFIG="${WORKDIR}/docker-operator" crane "$@"; }

apply_registry() {
  terraform -chdir="${WORKDIR}/registry" apply -auto-approve -input=false "$@" >/dev/null &&
    settle
}

write_stacks() {
  mkdir -p "${WORKDIR}/registry" "${WORKDIR}/consumer"

  cat >"${WORKDIR}/registry/main.tf" <<TF
provider "aws" {
  region  = "${REGION}"
  profile = "${REGISTRY_PROFILE}"
}

variable "narrow" {
  type    = bool
  default = false
}

variable "overbroad" {
  type    = bool
  default = false
}

data "aws_caller_identity" "current" {}

module "registry" {
  source = "${MODULE_DIR}"

  consumer_accounts = {
    "${CONSUMER_ACCOUNT}" = {
      principal_arn_patterns = var.narrow ? ["arn:aws:iam::${CONSUMER_ACCOUNT}:role/sbx-node-*"] : []
    }
  }
  pull_repository_prefixes = ["mirror"]

  # The over-broad pass-through: grants the consumer pull on EVERY
  # repository. ConsumerDenyProtected must still keep quarantine shut.
  additional_policy_statements = var.overbroad ? [{
    sid        = "SandboxOverbroad"
    effect     = "Allow"
    principals = [{ type = "AWS", identifiers = ["arn:aws:iam::${CONSUMER_ACCOUNT}:root"] }]
    actions    = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources  = ["arn:aws:ecr:${REGION}:\${data.aws_caller_identity.current.account_id}:repository/*"]
  }] : []

  scanning = {
    scan_type = "BASIC"
    rules     = [{ scan_frequency = "SCAN_ON_PUSH", filters = ["mirror/*"] }]
  }
}

output "registry_policy_json" {
  value = module.registry.registry_policy_json
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

# sbx-node-a matches the narrowing pattern; sbx-other does not. Both
# carry the same identity policy, so only the registry policy differs.
resource "aws_iam_role" "this" {
  for_each = toset(["sbx-node-a", "sbx-other"])

  name = each.key
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { AWS = "arn:aws:iam::${CONSUMER_ACCOUNT}:root" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "this" {
  for_each = aws_iam_role.this

  name   = "ecr-consumer"
  role   = each.value.id
  policy = var.identity_policy_json
}
TF
}

push_canaries() {
  local empty="${WORKDIR}/empty.tar" repo
  tar cf "${empty}" --files-from /dev/null
  reg ecr get-login-password | op_crane auth login "${REGISTRY_HOST}" -u AWS --password-stdin >/dev/null 2>&1
  for repo in mirror/sbx/canary quarantine/sbx/canary; do
    reg ecr create-repository --repository-name "${repo}" >/dev/null
    op_crane append -f "${empty}" -t "${REGISTRY_HOST}/${repo}:canary" >/dev/null 2>&1
  done
  CANARY_DIGEST="$(op_crane digest "${REGISTRY_HOST}/mirror/sbx/canary:canary")"
}

cleanup() {
  set +e
  if [[ "${KEEP:-0}" == "1" ]]; then
    log "KEEP=1: leaving ${WORKDIR} and the stacks in place"
    return
  fi
  reg ecr delete-repository --repository-name mirror/sbx/canary --force >/dev/null 2>&1
  reg ecr delete-repository --repository-name quarantine/sbx/canary --force >/dev/null 2>&1
  terraform -chdir="${WORKDIR}/registry" destroy -auto-approve -input=false >/dev/null 2>&1
  terraform -chdir="${WORKDIR}/consumer" destroy -auto-approve -input=false \
    -var identity_policy_json='{}' >/dev/null 2>&1
  rm -rf "${WORKDIR}"
}

main() {
  : >"${RESULTS}"
  REGISTRY_ACCOUNT="$(aws --profile "${REGISTRY_PROFILE}" sts get-caller-identity --query Account --output text)"
  CONSUMER_ACCOUNT="$(aws --profile "${CONSUMER_PROFILE}" sts get-caller-identity --query Account --output text)"
  REGISTRY_HOST="${REGISTRY_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
  log "registry ${REGISTRY_ACCOUNT}, consumer ${CONSUMER_ACCOUNT}, region ${REGION}, $(date -u +%FT%TZ)"
  log "tools: $(terraform version | head -1), $(aws --version), crane $(crane version)"

  # Safety: never overwrite a registry policy someone else owns.
  if reg ecr get-registry-policy >/dev/null 2>&1 && [[ "${SANDBOX_FORCE:-0}" != "1" ]]; then
    fail "the registry already has a policy; use a dedicated sandbox account (or SANDBOX_FORCE=1)"
  fi
  record "initial scope: $(reg ecr get-account-setting --name REGISTRY_POLICY_SCOPE --query value --output text 2>&1)"
  record "initial scanning: $(reg ecr get-registry-scanning-configuration --query scanningConfiguration --output json 2>&1 | jq -c .)"

  trap cleanup EXIT
  write_stacks
  terraform -chdir="${WORKDIR}/registry" init -input=false >/dev/null
  terraform -chdir="${WORKDIR}/consumer" init -input=false >/dev/null

  # P1 ordering: start from V1, one apply must switch to V2 and then
  # write the pull policy (the module's depends_on).
  reg ecr put-account-setting --name REGISTRY_POLICY_SCOPE --value V1 >/dev/null
  if apply_registry; then
    pass "P1 ordering: one apply from V1 set V2 and wrote the policy"
  else
    fail "P1 ordering: the apply from V1 failed"
  fi
  [[ "$(reg ecr get-account-setting --name REGISTRY_POLICY_SCOPE --query value --output text)" == "V2" ]] ||
    fail "P1 ordering: scope is not V2 after apply"

  terraform -chdir="${WORKDIR}/consumer" apply -auto-approve -input=false \
    -var identity_policy_json="$(terraform -chdir="${WORKDIR}/registry" output -raw consumer_identity_policy_json)" >/dev/null
  sleep 15 # IAM propagation for the new roles
  push_canaries

  # P1: no repository policy on the canary; the registry policy alone
  # grants the pull.
  expect_allowed sbx-node-a "${REGISTRY_HOST}/mirror/sbx/canary@${CANARY_DIGEST}" \
    "P1: consumer pulls mirror by digest with no repository policy (V2)"

  # P2: quarantine refused, mirror allowed.
  expect_refused sbx-node-a "${REGISTRY_HOST}/quarantine/sbx/canary:canary" \
    "P2: consumer refused on quarantine"

  # P2 with an over-broad pass-through: ConsumerDenyProtected must win.
  apply_registry -var overbroad=true
  expect_refused sbx-node-a "${REGISTRY_HOST}/quarantine/sbx/canary:canary" \
    "P2 over-broad: explicit Deny still refuses quarantine"
  expect_allowed sbx-node-a "${REGISTRY_HOST}/mirror/sbx/canary:canary" \
    "P2 over-broad: mirror still allowed"

  # Narrowing: sbx-node-* allowed, sbx-other refused.
  apply_registry -var narrow=true
  expect_allowed sbx-node-a "${REGISTRY_HOST}/mirror/sbx/canary:canary" \
    "narrowing: matching role allowed"
  expect_refused sbx-other "${REGISTRY_HOST}/mirror/sbx/canary:canary" \
    "narrowing: non-matching role refused"
  apply_registry

  # P1 V1 probe: does a real V1 registry reject the pull grant at
  # PutRegistryPolicy (as LocalStack Pro does), or accept it and fail
  # the pull? Either answer is the finding.
  # The policy is removed first: a V1 switch with V2 actions still in
  # the policy may itself be refused, and the probe would then run on V2.
  record "V1 switch with the V2 policy in place: $(reg ecr put-account-setting --name REGISTRY_POLICY_SCOPE --value V1 2>&1 | tr '\n' ' ')"
  reg ecr delete-registry-policy >/dev/null 2>&1 || true
  reg ecr put-account-setting --name REGISTRY_POLICY_SCOPE --value V1 >/dev/null
  record "scope for the probe: $(reg ecr get-account-setting --name REGISTRY_POLICY_SCOPE --query value --output text)"
  record "V1 PutRegistryPolicy with the pull grant: $(reg ecr put-registry-policy \
    --policy-text "$(terraform -chdir="${WORKDIR}/registry" output -raw registry_policy_json)" 2>&1 | jq -c . 2>/dev/null || true)"
  if can_pull sbx-node-a "${REGISTRY_HOST}/mirror/sbx/canary:canary"; then
    record "V1 consumer pull: SUCCEEDED"
  else
    record "V1 consumer pull: REFUSED"
  fi
  apply_registry # back to V2 + policy

  # Destroy: the consumer is refused afterwards; observe what destroy
  # leaves for the scope and scanning singletons.
  terraform -chdir="${WORKDIR}/registry" destroy -auto-approve -input=false >/dev/null
  expect_refused sbx-node-a "${REGISTRY_HOST}/mirror/sbx/canary:canary" \
    "destroy: consumer refused after the policy is gone"
  record "scope after destroy: $(reg ecr get-account-setting --name REGISTRY_POLICY_SCOPE --query value --output text 2>&1)"
  record "scanning after destroy: $(reg ecr get-registry-scanning-configuration --query scanningConfiguration --output json 2>&1 | jq -c .)"

  log "done; P3 is manual (README.md)"
}

main "$@"
