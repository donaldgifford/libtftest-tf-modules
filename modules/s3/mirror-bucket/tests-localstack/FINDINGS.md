<!-- markdownlint-disable-file MD025 MD041 -->
# tests-localstack findings — modules/s3/mirror-bucket

## Summary

The mirror bucket is **pure S3 + STS**, so it applies against
**LocalStack Community** with no Pro tier, no auth token, and no
named-volume workaround. The suite exercises the explicit-target
logging posture (no remote-state read anywhere), the pinned serving
posture, and the stored seven-statement policy — against the
emulator's faithful config surface (probe P1), not its
policy evaluation (probe P2, negative as expected).

## Environment (verified 2026-09-15)

| Component | Value |
|-----------|-------|
| Image | `localstack/localstack:4.4` (Community) |
| Services | `SERVICES=s3,sts` |
| Startup | token-free; healthy in ~20s |
| Result | `just tf test-localstack s3/mirror-bucket` → **3 passed, 0 failed** |

## What the apply exercised

- `run "setup"` — the fixture owns a **plain** target bucket
  (`mirror-logs-target-000000000000-us-east-1`). No sink module, no
  state key: the mirror names its logging target explicitly, so the
  `s3/bucket` composing-fixture shape does not apply here.
- `run "apply_full_shape"` — explicit logging target + prefix
  default resolved post-apply; both lifecycle rules present; all
  seven sids stored on the applied policy (four mirror + three
  baseline/backstop); SSE-S3 + versioning Enabled + VPCE deny +
  `mirror_url` held.
- `run "apply_minimal"` — logging fully off, baseline lifecycle
  rule only, stored delete-deny unconditional (no `Condition`
  key).

The provider needs `s3_use_path_style = true`.

## Probe P1 — star-principal policy fidelity: **POSITIVE**

Manual probe (IMPL-0025 OQ 3): `put-bucket-policy` with the exact
mirror statement shapes (`Principal: "*"`, `StringEquals
aws:SourceVpce`, multi-action delete-deny), then `get-bucket-policy`
readback. LocalStack 4.4 Community round-trips the document
**faithfully** — sid, Principal, Action list, Resource, and
Condition all byte-identical.

**Consequence:** the suite's stored-policy assertions (seven sids,
unconditional delete-deny) assert against a faithful stored
surface — no assertable-depth reduction needed, Community stays
the only apply tier.

## Probe P2 — policy enforcement: **NEGATIVE (expected)**

With `DenyObjectDeletion` (absolute, no condition) stored on the
bucket, `s3 rm` of a canary object **succeeded**, and the bucket
deleted cleanly at teardown. LocalStack Community 4.4 **stores**
bucket policies faithfully but does **not evaluate** them.

**Consequence:** enforcement semantics (VPCE-only reads, denied
deletes/mutations) belong to the sandbox run (`tests-sandbox/`,
negative legs in IMPL-0025 scope, positive leg in gh-122) — never
to this tier. No test here asserts evaluation.

## To reproduce

```bash
docker run -d --name ls-s3-mirror -p 4566:4566 \
  -e SERVICES=s3,sts localstack/localstack:4.4
# wait for /_localstack/health to report s3 available, then:
just tf test-localstack s3/mirror-bucket
docker rm -f ls-s3-mirror
```
