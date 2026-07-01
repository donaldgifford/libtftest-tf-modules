<!-- markdownlint-disable-file MD025 MD041 MD013 -->
# tests-localstack: Findings

Gap-discovery write-ups for `modules/efs/filesystem` per RFC-0001 +
DESIGN-0008 §Testing Strategy.

This document captures what LocalStack actually serves for the
module's EFS surface, the gaps that surface during `terraform test`
runs against LocalStack, and the 501/NotImplemented errors that
warrant a sneakystack ticket per RFC-0001.

## Test runs

The `apply_localstack.tftest.hcl` suite has three active runs (as of the
Pro 2026.6.0 sweep, 2026-07-01):

| Run | Command | Coverage |
|-----|---------|----------|
| `setup` | apply | VPC + 3 private subnets + standalone node-SG stub + S3 bucket holding TWO stub state files (VPC + EKS) |
| `plan_smoke` | plan | EFS filesystem + 3 mount targets + 1 module-managed KMS key + NFS ingress all wire against LocalStack at plan time |
| `apply_default` | apply | **Real EFS create** — filesystem + 3 mount targets + 1 access point (posix_user.uid=472 enforced) + module KMS key, applied and asserted against LocalStack Pro |

Run with `just tf test-localstack efs/filesystem`. The recipe wires
`AWS_ENDPOINT_URL=http://localhost:4566` + fake credentials.

One `apply_*` run remains commented HCL: `apply_backup_enabled`
(`PutBackupPolicy` still 501s on Pro 2026.6.0 — Finding #2).

## Tier coverage

Per DESIGN-0008 Q11: this suite was designed tier-agnostic in
intent — same `apply_localstack.tftest.hcl` should pass identically
on Community + Pro once LocalStack's EFS coverage lands on
Community.

- **Verified tier**: LocalStack **Pro 2026.6.0** (2026-07-01) —
  `apply_default` runs end-to-end (**3 passed**), so this suite now takes
  the *pass* path of IMPL-0008 Phase 10's success criteria, not the
  fall-back. EFS is a Pro-only service (absent from Community — Finding #1).
- **Community 3.8.1** (historical, 2026-05-29): EFS API absent, so the
  suite ran `plan_smoke` only. Superseded by the Pro run above.

## Finding #1 — EFS API is Pro-only (absent from Community); served on Pro

**Status:** ✅ Resolved on Pro. As of 2026-07-01 the EFS apply path is
**verified on LocalStack Pro 2026.6.0**: `apply_default` creates the
filesystem, all 3 mount targets, and the access point (with
`posix_user.uid = 472` honored), with no 501. The gap below is
**Community-only**.

`efs` is **not** in LocalStack Community's service list per its
`/_localstack/health` endpoint; EFS is a LocalStack **Pro** feature.

**Behavior:** `terraform apply` against LocalStack Community 3.8.1
fails with:

```text
Error: creating EFS File System: operation error EFS: CreateFileSystem,
https response error StatusCode: 501,
api error InternalFailure: API for service 'efs' not yet implemented
or pro feature - please check https://docs.localstack.cloud/references/coverage/
for further information

  with aws_efs_file_system.this,
  on filesystem.tf line 21, in resource "aws_efs_file_system" "this":
```

The same 501 cascades to `aws_efs_mount_target`,
`aws_efs_access_point`, and `aws_efs_backup_policy` — every EFS
resource the module emits requires the EFS API to be implemented at
the LocalStack endpoint.

**Risk surface:** The filesystem + mount targets + access points
ARE the module's reason to exist (DESIGN-0008 / IMPL-0008). A
partial-apply that successfully creates only the KMS key + security
group + S3 stub state isn't meaningful coverage. So this suite
takes the IMPL-0005 Phase 9 fall-back: comment out the `apply_*`
runs, preserve them as code, and demote the active suite to
`plan_smoke`.

**Plan-time coverage holds:** A `terraform plan` against LocalStack
endpoints (EC2 + S3 for the setup fixture; EFS + KMS + IAM endpoint
resolution for the module) succeeds, because plan-time validation
talks to the provider schema rather than the AWS-API mock. Every
resource in the module validates without 501 at plan time —
501s only fire on the create call. Plan-smoke is therefore a
useful coverage signal: it proves provider endpoint resolution +
remote-state reads through the S3 stub state files + every
resource validates against the schema with the data we feed it.

**Sneakystack backlog item:** EFS API support on LocalStack
Community. Track against LocalStack issue tracker; re-run this
suite when it lands.

## Finding #2 — `aws_efs_backup_policy` (`PutBackupPolicy`) 501 on Pro 2026.6.0

**Status:** 🔴 Confirmed gap on Pro. With EFS now applying (Finding #1
resolved), the `apply_backup_enabled` run was probed on 2026-07-01 and
fails:

```text
Error: putting EFS Backup Policy (fs-…): operation error EFS: PutBackupPolicy,
https response error StatusCode: 501,
api error InternalFailure: The put_backup_policy action has not been implemented
  with aws_efs_backup_policy.this[0],
  on backup.tf line 12, in resource "aws_efs_backup_policy" "this":
```

So `apply_default` (core EFS) is active, but `apply_backup_enabled`
remains commented per the RFC-0001 fall-back. Re-enable when LocalStack
implements `PutBackupPolicy`. Track as a sneakystack backlog item.

## What's still in the libtftest backlog (RFC-0001 §Phase 3)

Surface that no `terraform test` plan or apply can validate without
a running consumer + a real NFS client — filed in the libtftest /
sneakystack backlog:

- Actual NFS mount through the CSI driver — proves that pods can
  open files via `mount.nfs4` against the mount target.
- Access-point UID enforcement on file operations — proves that
  `posix_user.uid = 472` actually forces ownership of every file
  written through the access point.
- Encryption-in-transit (`encryptInTransit: "true"` PV
  volumeAttribute) handshake — proves the CSI driver negotiates
  TLS-wrapped NFS through `stunnel`.
- Cross-AZ mount-target selection by the CSI driver — proves the
  driver picks the AZ-matching mount target when scheduling a pod.

## When to re-run

Re-run `just tf test-localstack efs/filesystem`:

1. After a LocalStack release that lists `efs` in the
   `/_localstack/health` service list on Community, OR after a
   LocalStack Pro environment becomes available (set
   `LOCALSTACK_AUTH_TOKEN`).
2. After modifying the module's resource set such that the wiring
   of `aws_efs_file_system` changes (new lifecycle blocks, new
   attribute defaults, etc.) — the `plan_smoke` run catches
   schema-level regressions.

When re-running:

1. Uncomment the `apply_default` + `apply_backup_enabled` runs in
   `apply_localstack.tftest.hcl`.
2. Verify the assertions hold against the live LocalStack EFS API.
3. If new failures surface, file a fresh Finding here.
