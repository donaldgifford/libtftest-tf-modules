#!/usr/bin/env bash
# Sandbox policy-evaluation runbook — NEGATIVE LEGS ONLY
# (IMPL-0025 task 3.3; the VPCE positive leg is gh-122, not here).
#
# Proves against real AWS: direct anonymous GET fails, delete as a
# non-break-glass principal fails, put-bucket-policy as a non-admin
# fails. Nothing here evaluates the VPCE path.
#
# Prerequisites:
#   - AWS credentials for the SANDBOX account (env or --profile),
#     terraform + aws cli + curl installed.
#   - BREAK_GLASS_ARN: this caller's own ARN (aws sts
#     get-caller-identity), used for canary cleanup only.
#
# Usage:
#   BREAK_GLASS_ARN="arn:aws:iam::<acct>:role/<you>" \
#   MIRROR_NAME="sandbox-mirror" ACCOUNT_ID="<12-digit>" REGION="us-east-1" \
#   ADMIN_ARN="arn:aws:iam::<acct>:role/<admin>" ./run.sh
#
# Exit non-zero on any unexpected result. Destroys everything it
# creates (bucket included — lock stays OFF for this run).

set -euo pipefail

: "${MIRROR_NAME:?set MIRROR_NAME}"
: "${ACCOUNT_ID:?set ACCOUNT_ID}"
: "${REGION:=us-east-1}"
: "${ADMIN_ARN:?set ADMIN_ARN}"
: "${BREAK_GLASS_ARN:?set BREAK_GLASS_ARN}"

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# ^ not used for apply (see below); the runbook applies the module
# from the repo checkout via an ephemeral wrapper so the proof runs
# against the exact working tree.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

BUCKET="${MIRROR_NAME}-${ACCOUNT_ID}-${REGION}"
URL="https://${BUCKET}.s3.${REGION}.amazonaws.com/canary.txt"

cd "${WORKDIR}"
cat > main.tf <<EOF
module "mirror" {
  source                      = "${MODULE_DIR}/modules/s3/mirror-bucket"
  name                        = "${MIRROR_NAME}"
  account_id                  = "${ACCOUNT_ID}"
  region                      = "${REGION}"
  vpc_endpoint_ids            = ["vpce-00000000000000000"]
  policy_admin_principal_arns = ["${ADMIN_ARN}"]
  access_log_bucket           = null
  force_destroy               = true
}
EOF

terraform init -input=false >/dev/null
terraform apply -auto-approve -input=false >/dev/null

# Canary object as the operator (allowed — no delete involved).
echo "canary" > canary.txt
aws s3 cp canary.txt "s3://${BUCKET}/canary.txt" --region "${REGION}" >/dev/null \
  || fail "canary upload as operator"

# Leg 1: direct anonymous GET must fail (403, not 404 — the object exists).
CODE="$(curl -s -o /dev/null -w "%{http_code}" "${URL}")"
if [ "${CODE}" = "403" ]; then
  pass "direct anonymous GET denied (${CODE})"
else
  fail "direct anonymous GET returned ${CODE}, want 403"
fi

# Leg 2: delete as a non-break-glass principal must fail.
if aws s3 rm "s3://${BUCKET}/canary.txt" --region "${REGION}" 2>/dev/null; then
  fail "delete as non-break-glass succeeded"
else
  pass "delete as non-break-glass denied"
fi

# Leg 3: put-bucket-policy as a non-admin must fail.
if aws s3api put-bucket-policy --bucket "${BUCKET}" \
  --policy '{"Version":"2012-10-17","Statement":[]}' \
  --region "${REGION}" 2>/dev/null; then
  fail "put-bucket-policy as non-admin succeeded"
else
  pass "put-bucket-policy as non-admin denied"
fi

# Cleanup: re-apply with THIS caller as break-glass, delete canary, destroy.
cat > main.tf <<EOF
module "mirror" {
  source                      = "${MODULE_DIR}/modules/s3/mirror-bucket"
  name                        = "${MIRROR_NAME}"
  account_id                  = "${ACCOUNT_ID}"
  region                      = "${REGION}"
  vpc_endpoint_ids            = ["vpce-00000000000000000"]
  policy_admin_principal_arns = ["${ADMIN_ARN}"]
  break_glass_principal_arns  = ["${BREAK_GLASS_ARN}"]
  access_log_bucket           = null
  force_destroy               = true
}
EOF
terraform apply -auto-approve -input=false >/dev/null
aws s3 rm "s3://${BUCKET}/canary.txt" --region "${REGION}" >/dev/null \
  || fail "break-glass canary delete"
pass "break-glass canary delete (cleanup path works)"
terraform destroy -auto-approve -input=false >/dev/null
pass "destroy clean"

echo "ALL SANDBOX NEGATIVE LEGS PASS"
