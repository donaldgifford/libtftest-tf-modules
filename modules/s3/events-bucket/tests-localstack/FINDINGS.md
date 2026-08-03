<!-- markdownlint-disable-file MD025 MD041 -->
# tests-localstack findings — modules/s3/events-bucket

## Summary

The events bucket applies against **LocalStack Community** — S3 + STS
for the bucket and its reserved-key read, SQS/SNS/EventBridge for the
notification destinations. No Pro tier, no auth token, no named
volume. The suite covers the notification singleton and the inherited
access-logging tri-state on a real apply.

## Environment (verified 2026-08-03)

| Component | Value |
|-----------|-------|
| Image | `localstack/localstack:4.4` (Community) |
| Services | `SERVICES=s3,sts,sqs,sns,events` |
| Startup | token-free; healthy in ~20s |
| Result | `just tf test-localstack s3/events-bucket` → **3 passed, 0 failed** |

## What the apply exercised

- `run "setup"` — the fleet state bucket, the **real**
  `access-logs-bucket` module seeded at the reserved ADR-0020 key, an
  SQS queue **with its queue policy**, and an SNS topic. The queue
  policy lives in the fixture on purpose: destination resource
  policies are owned by the destination stack, and the fixture is the
  worked example of the shape a consumer must provide.
- `run "apply_with_sqs"` — the applied notification configuration
  carried the real queue ARN, the singleton's id equalled the bucket
  name, EventBridge stayed off, the default tri-state resolved the
  sink through the reserved key, and the F2 baseline held.
- `run "apply_with_all_destinations"` — queue + topic + EventBridge on
  one singleton resource, with logging disabled.

## F6 probe 2 — notification firing: **POSITIVE**

Manual probe (DESIGN-0019 OQ 4a), run outside `terraform test`:

1. Created `probe-q` (with an `s3.amazonaws.com` SendMessage policy)
   and bucket `probe-events`.
2. `put-bucket-notification-configuration` for
   `s3:ObjectCreated:*` → the queue.
3. `put-object`, then `receive-message`.

**Result:** two messages arrived within seconds — the
`s3:TestEvent` handshake S3 sends when a configuration is registered,
and a full `ObjectCreated:Put` record with the correct
`configurationId`, bucket name/ARN, object key, size, and eTag.
LocalStack Community 4.4 implements S3 → SQS notification delivery
faithfully.

**What is baked, and why not more.** The positive probe confirms the
*emulator's* fidelity, but `terraform test` has no mechanism to
receive an SQS message — there is no data source that reads from a
queue, and pulling in the `external` provider to shell out would add a
provider dependency to a module that needs none. So the suite still
asserts the **configuration surface** (attribute-derived
`notification_queue_arns` / `notification_topic_arns` /
`eventbridge_enabled`, read back from the applied resource). Here the
limiter is the test harness, not LocalStack — the opposite of
[probe 1](../../bucket/tests-localstack/FINDINGS.md), where the
emulator itself never delivers.

**Second finding — LocalStack does NOT enforce the destination
policy.** A follow-up probe registered a notification to a queue with
*no* policy at all; real S3 rejects this
(`InvalidArgument: Unable to validate the following destination
configurations`), but LocalStack accepted it (exit 0). So the apply
suite's success does **not** prove the fixture's queue policy is
correct — the policy is documented and demonstrated, not verified.
Treat the README's destination-policy section as the contract.

## To reproduce

```bash
docker run -d --name ls-s3-events -p 4566:4566 \
  -e SERVICES=s3,sts,sqs,sns,events localstack/localstack:4.4
# wait for /_localstack/health to report sqs available, then:
just tf test-localstack s3/events-bucket
docker rm -f ls-s3-events
```
