# LocalStack findings — s3/evidence-bucket

Community apply suite (`apply_localstack.tftest.hcl`) against
**token-free `localstack/localstack:4.4` (Community), `SERVICES=s3,sts`**.
Run and passing, 1/1 (2026-09-04).

## Probe A — config surface: POSITIVE (asserted by the suite)

4.4 accepts `object_lock_enabled` at bucket create and
`PutObjectLockConfiguration`, and the applied default retention
round-trips: the suite's `object_lock` output assertion
(`COMPLIANCE` / `days = 1`) reads the config resource's actual
post-apply attributes. Versioning `Enabled` and the full F2 baseline
hold on a locked bucket.

## Probe B — retention enforcement: POSITIVE (recorded, not baked)

Probed via CLI against the same container (INV-0011 F4 called this
unprobed territory). 4.4 Community goes beyond config round-trip —
it applies **and enforces** default retention:

- `put-object` on the locked bucket mints a version carrying the
  bucket default: `get-object-retention` returns
  `{"Mode": "COMPLIANCE", "RetainUntilDate": <now + 1 day>}`.
- `delete-object --version-id` on that version is **denied**:

  ```text
  An error occurred (AccessDenied) when calling the DeleteObject
  operation: Access Denied because object protected by object lock.
  ```

  and the version survives `list-object-versions`.

**The baked suite still asserts only the config surface**
(DESIGN-0022 OQ 2 resolution / the family's assert-what-round-trips
rule): enforcement is AWS's contract, and a `terraform test` run
cannot attempt a version delete anyway. The suite writes **no
objects** and keeps `retention.days = 1`, so teardown never fights
COMPLIANCE mode — probe B's locked version lived in a throwaway
probe bucket inside the ephemeral container, not in the suite's
bucket. Do not add object writes to this suite: with enforcement
confirmed real, a locked version would make `terraform test`
teardown (and the bucket) undeletable until retention expires.

## Suite shape

Standalone on purpose — logging disabled, so no remote-state read,
no fixture, no `run "setup"`. The tri-state's live proof is the
`bucket` module's apply suite; this module's plan suite pins its
reserved-key composition. Same env wiring as the family
(`AWS_ENDPOINT_URL`, path-style S3).
