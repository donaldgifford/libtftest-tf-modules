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
