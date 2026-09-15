<!-- markdownlint-disable-file MD025 MD041 -->
# tests-sandbox findings — modules/s3/mirror-bucket

## Status: runbook authored, live execution PENDING

The negative-leg runbook (`run.sh`) is written and shellcheck-clean
but has **not been run live**: this environment holds no AWS
credentials for a sandbox account. Execution is an operator step:

```bash
BREAK_GLASS_ARN="arn:aws:iam::<acct>:role/<you>" \
MIRROR_NAME="sandbox-mirror" ACCOUNT_ID="<12-digit>" REGION="us-east-1" \
ADMIN_ARN="arn:aws:iam::<acct>:role/<admin>" ./run.sh
```

Paste the resulting `PASS` lines below when run.

## Scope (deliberate)

Negative legs only, per IMPL-0025 OQ 2 (resolved c, moved out):

1. Direct anonymous GET fails (403 — object exists, so 404 would
   mean the canary setup failed, not the policy).
2. Delete as a non-break-glass principal fails (the deny hits
   everyone outside `break_glass_principal_arns`, admin included).
3. `put-bucket-policy` as a non-admin fails.
4. Cleanup path works: re-apply with the caller as break-glass,
   delete the canary, destroy (lock stays OFF for this run).

The VPCE positive leg (anonymous GET via the endpoint succeeds) is
**gh-122**, not this runbook — it needs an in-VPC client
(VPC-attached runners, sluice workstreams 3/5).

## Results

PENDING — no live run yet (no sandbox credentials in the authoring
environment).
