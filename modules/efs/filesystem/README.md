<!-- markdownlint-disable-file MD025 MD041 -->
# EFS Filesystem Module

Provisions an Amazon EFS filesystem with module-managed KMS encryption,
one mount target per VPC private subnet, NFS ingress from the EKS node
security group (resolved via cluster remote state), an optional
declarative access-point map, and an optional AWS Backup policy. Pairs
with the EFS CSI driver already installed by `modules/eks/addons` when
`var.efs_csi_enabled = true` — this module covers the AWS-API surface;
the CSI driver covers the Kubernetes-API surface.

Implements
[IMPL-0008](../../../docs/impl/0008-efs-filesystem-module-implementation.md)
/ [DESIGN-0008](../../../docs/design/0008-efs-module-layout-for-efs-csi-on-eks.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Prerequisites

1. **VPC stack landed first** — applied to the same AWS account +
   region as the EKS cluster, with state written to S3 at
   `<region>/vpc/<vpc_name>/terraform.tfstate`. Required outputs:
   `vpc_id`, `private_subnet_ids`.
2. **EKS cluster stack landed first** — applied to the same account
   + region, with state at `<region>/eks/<cluster_name>/terraform.tfstate`.
   Required output: `node_security_group_id`. The existing EKS
   cluster module already emits this.
3. **EKS addons module with `var.efs_csi_enabled = true`** — the
   cluster-side prerequisite for any CSI-driver consumer of this
   filesystem. Not a Terraform-level dependency (the operator can
   apply the addon and this module independently); CSI-driver mounts
   simply won't work until both sides land.
4. **S3 backend bucket** exists and is reachable from the runner
   applying this module.
5. **LocalStack** — optional. The `tests-localstack/` suite expects
   a container on `:4566`. EFS coverage in LocalStack Community
   3.8.1 is 501 (per `tests-localstack/FINDINGS.md` §Finding #1) —
   the active suite is `plan_smoke`; the apply runs are preserved
   as commented HCL for re-enable when LocalStack Pro 2026.5.0
   (or future Community releases with EFS) is available.

## Instantiation

### Minimal example

```hcl
module "platform_efs" {
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/efs/filesystem?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  cluster_name        = "platform-prod"
  identifier_prefix   = "platform-efs"

  tags = {
    Service     = "platform-api"
    Environment = "production"
  }
}
```

This wires:

- A module-managed KMS key + alias `alias/platform-efs-efs` with
  `enable_key_rotation = true` and `lifecycle { prevent_destroy = true }`.
- An EFS filesystem with `creation_token = "platform-efs"`,
  `performance_mode = "generalPurpose"`, `throughput_mode = "elastic"`,
  and the default IA-after-30-days + Archive-after-90-days lifecycle.
- One `aws_efs_mount_target` per private subnet from VPC remote state.
- A security group with NFS ingress from the EKS node SG.

### Bring-your-own KMS

```hcl
module "compliance_efs" {
  source = "..."

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  cluster_name        = "platform-prod"
  identifier_prefix   = "compliance-efs"

  kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/abc-def-ghi"
}
```

When `kms_key_arn` is set, the module skips its internal key + alias
(zero count gate). The caller is responsible for the BYO key's
rotation, deletion-window, and grants.

### Multiple access points

```hcl
module "observability_efs" {
  source = "..."

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  vpc_name            = "platform-prod"
  cluster_name        = "platform-prod"
  identifier_prefix   = "observability-efs"

  access_points = {
    grafana = {
      posix_user = {
        uid = 472
        gid = 472
      }
      root_directory = {
        path = "/grafana"
        creation_info = {
          owner_uid   = 472
          owner_gid   = 472
          permissions = "0755"
        }
      }
    }
    prometheus = {
      posix_user = {
        uid            = 65534
        gid            = 65534
        secondary_gids = [10, 20]
      }
      root_directory = {
        path = "/prometheus"
      }
    }
  }
}
```

The map key (`grafana`, `prometheus`) flows into the access point's
`Name` tag and into the `access_point_ids` + `access_point_arns`
output maps. PV manifests reference these by key.

### Backup policy opt-in

```hcl
module "backed_up_efs" {
  source = "..."

  # ... required inputs ...

  backup_policy_enabled = true
}
```

Enables the AWS-managed default backup vault for this filesystem.
Operators rely on the default vault's retention + lifecycle policy
unless they configure overrides directly in AWS Backup.

### Additional consumer security groups

```hcl
module "shared_efs" {
  source = "..."

  # ... required inputs ...

  additional_allowed_consumer_sg_ids = [
    "sg-0123456789abcdef0", # batch job runners
    "sg-fedcba9876543210f", # peer-VPC backup agent
  ]
}
```

The default `from_nodes` ingress (NFS 2049 from the EKS node SG)
remains; the listed SGs get their own `from_extra` ingress rules
on the same SG. EFS CSI driver consumers don't need this — the
EKS node SG ingress already covers them.

## Consuming the filesystem from EKS

This module ships no Kubernetes manifests (per ADR-0011 — K8s
objects are delivered out-of-band via `kubectl apply` for
homelab/dev or Argo CD + Kustomize for production).

### Static-provisioning PV manifest

For an access-point-scoped PV, the `volumeHandle` uses the
`<filesystem_id>::<access_point_id>` shape:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grafana-efs
spec:
  capacity:
    storage: 100Gi   # ignored for EFS; required by the API
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  csi:
    driver: efs.csi.aws.com
    volumeHandle: fs-0123456789abcdef0::fsap-0fedcba9876543210
    volumeAttributes:
      encryptInTransit: "true"
```

Pull `fs-...` from `module.observability_efs.filesystem_id` and
`fsap-...` from `module.observability_efs.access_point_ids["grafana"]`.

For a root-mount PV (no access point), use just the filesystem ID:

```yaml
  csi:
    driver: efs.csi.aws.com
    volumeHandle: fs-0123456789abcdef0
```

The corresponding PVC + StorageClass live in the same out-of-band
delivery channel.

### Dynamic provisioning

Dynamic provisioning via the EFS CSI driver is out of scope here —
it requires a StorageClass referencing this filesystem, which is
itself a K8s manifest. See the [aws-efs-csi-driver upstream
docs](https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/examples/kubernetes/dynamic_provisioning/README.md).

## Operational gotchas

### KMS key with `prevent_destroy = true`

The module-managed KMS key carries `lifecycle { prevent_destroy =
true }`. Destroying the filesystem doesn't destroy the key —
operators unblock destruction via a deliberate two-step PR:

1. Confirm no files in the filesystem (or that re-encrypt is fine).
2. Remove the `lifecycle { prevent_destroy = true }` block in
   `kms.tf` AND any resources still referencing it.
3. Apply + destroy.

This is mostly relevant in dev environments — production
filesystems should keep the key indefinitely to avoid losing
access to snapshots / backup vaults encrypted with it.

### Mount target tags

The `aws_efs_mount_target` resource does not accept a `tags`
attribute in the AWS Terraform provider (`hashicorp/aws ~> 6.2`)
— mount targets inherit their ENI's tags from the AWS side and
the provider exposes no override. The module's `var.tags` is
applied to the filesystem + access points + security group + KMS
key, but not the mount targets. If you need mount-target-specific
tags, tag the underlying ENIs directly via AWS CLI.

### `creation_token` collision on destroy + immediate re-apply

Per DESIGN-0008 Q10, `creation_token = var.identifier_prefix`
is deterministic with no random suffix. EFS keeps the token in
its delete-pending state for a short window after a filesystem
is destroyed; if you `terraform apply` again with the same
`identifier_prefix` during that window, AWS returns a
`TokenAlreadyExists` error.

The fix is to wait (typically 30-60 seconds) and re-apply. The
collision is rare — destroy + immediate re-apply of the same
identifier is an uncommon workflow.

### Lifecycle policy IA-transition latency

EFS's lifecycle policy moves files between Standard, IA, and
Archive storage classes asynchronously. Newly written files don't
transition for `AFTER_30_DAYS` of inactivity (under the default
`transition_to_ia`); operators occasionally observe an apparent
"lag" between flipping the policy and seeing storage-class
changes in the EFS console. This is AWS-side behavior, not a
module gap.

### AWS Backup vault prerequisite

When `backup_policy_enabled = true`, AWS Backup uses the default
backup vault (`Default`) in the same account + region. If that
vault doesn't exist, the AWS API auto-creates it; if site policy
prohibits the default vault (per a custom `BackupPolicy` SCP),
this module's backup-policy resource will fail. The fix is to
keep `backup_policy_enabled = false` and configure AWS Backup
elsewhere, or to provision a non-default vault out-of-band and
attach this filesystem's backup-plan selection via a separate
plan-resource module (future IMPL).

## Tests

```bash
# Plan-only suite (~5s, no LocalStack):
just tf test efs/filesystem

# LocalStack gap-discovery suite (active = plan_smoke; apply runs
# preserved as commented HCL — see tests-localstack/FINDINGS.md):
just tf test-localstack efs/filesystem
```

## Module map

| File | Purpose |
|------|---------|
| `versions.tf` | Provider + Terraform version pins |
| `variables.tf` | Full input contract (14 variables) |
| `main.tf` | `data.terraform_remote_state.{vpc,eks}` |
| `locals.tf` | KMS ARN coalesce, alias name, NFS port literal |
| `kms.tf` | Module-managed KMS key + alias (gated BYO; `prevent_destroy`) |
| `network.tf` | Security group + granular `from_nodes` / `from_extra` ingress + egress rules |
| `filesystem.tf` | `aws_efs_file_system` + dynamic lifecycle policy blocks + cross-var precondition |
| `mount_targets.tf` | `aws_efs_mount_target` for_each over private subnets |
| `access_points.tf` | `aws_efs_access_point` for_each over `var.access_points` |
| `backup.tf` | Gated `aws_efs_backup_policy` |
| `outputs.tf` | 9 consumer-contract outputs |
| `tests/` | Plan-only `terraform test` suite (23 runs) |
| `tests-localstack/` | Gap-discovery apply suite (plan_smoke fall-back) + FINDINGS.md |
