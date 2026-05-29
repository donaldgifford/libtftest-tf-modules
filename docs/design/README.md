# Design Documents

This directory contains detailed design documents for feature implementation.

## What are Design Documents?

Design documents describe **how a feature or system will be built**. Each design
document includes:

- **Overview**: What is being designed and why
- **Goals and Non-Goals**: Scope boundaries
- **Detailed Design**: Architecture, APIs, data models
- **Testing Strategy**: How the design will be validated
- **Migration Plan**: How to roll out the changes

## Creating a New Design Document

```bash
docz create design "Your Design Title"
```

## Design Status

- **Draft**: Initial draft, still being written
- **In Review**: Ready for review and feedback
- **Approved**: Approved and ready for implementation
- **Implemented**: Design has been fully implemented
- **Abandoned**: Design was not pursued

<!-- BEGIN DOCZ AUTO-GENERATED -->
## All DESIGNs

| ID | Title | Status | Date | Author | Link |
|----|-------|--------|------|--------|------|
| DESIGN-0001 | Secure EKS Managed Node Group with gVisor | Accepted | 2026-05-13 | Donald Gifford | [0001-secure-eks-managed-node-group-with-gvisor.md](0001-secure-eks-managed-node-group-with-gvisor.md) |
| DESIGN-0002 | EKS Cluster Module | Accepted | 2026-05-13 | Donald Gifford | [0002-eks-cluster-module.md](0002-eks-cluster-module.md) |
| DESIGN-0003 | EKS Addons Module | Accepted | 2026-05-13 | Donald Gifford | [0003-eks-addons-module.md](0003-eks-addons-module.md) |
| DESIGN-0004 | EKS Pod Identity Access Module | Accepted | 2026-05-13 | Donald Gifford | [0004-eks-pod-identity-access-module.md](0004-eks-pod-identity-access-module.md) |
| DESIGN-0005 | ECR Pull-Through Cache Module | Draft | 2026-05-15 | Donald Gifford | [0005-ecr-pull-through-cache-module.md](0005-ecr-pull-through-cache-module.md) |
| DESIGN-0006 | Org-wide ECR OCI Artifact Registry | Draft | 2026-05-18 | Donald Gifford | [0006-org-wide-ecr-oci-artifact-registry.md](0006-org-wide-ecr-oci-artifact-registry.md) |
| DESIGN-0007 | RDS module layout: instance, Aurora cluster, Aurora read replica, Aurora Serverless | Draft | 2026-05-27 | Donald Gifford | [0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) |
| DESIGN-0008 | EFS module layout for EFS CSI on EKS | Draft | 2026-05-27 | Donald Gifford | [0008-efs-module-layout-for-efs-csi-on-eks.md](0008-efs-module-layout-for-efs-csi-on-eks.md) |
<!-- END DOCZ AUTO-GENERATED -->
