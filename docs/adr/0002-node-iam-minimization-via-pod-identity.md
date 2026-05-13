---
id: ADR-0002
title: "Node IAM minimization via Pod Identity"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0002. Node IAM minimization via Pod Identity

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
- [Consequences](#consequences)
  - [Positive](#positive)
  - [Negative](#negative)
  - [Neutral](#neutral)
- [Alternatives Considered](#alternatives-considered)
- [References](#references)
<!--toc:end-->

## Status

Accepted

## Context

The historical EKS node-role pattern attaches AWS-managed policies to the
EC2 instance role: `AmazonEKS_CNI_Policy` for VPC CNI,
`AmazonEBSCSIDriverPolicy` for the EBS CSI controller,
`AmazonEFSCSIDriverPolicy` for EFS, plus inline policies for cert-manager,
external-dns, ALB controller, cluster-autoscaler, external-secrets,
Velero, FluentD, CloudWatch agent, GuardDuty, etc. Every container on
every node inherits those credentials through IMDS.

That makes the node IAM role the blast radius of every node-level
compromise: a container escape, a supply-chain CVE in any DaemonSet image,
a hostNetwork pod that reaches IMDS, an SSRF in a workload — all of them
land on a role with broad standing privileges across CNI, CSI, Route 53,
ELB, Secrets Manager, and more.

Two things changed that make a much smaller node role practical:

1. **AWS now explicitly recommends moving off the node role.** From the
   official EKS docs: *"If the `AmazonEKS_CNI_Policy` policy is attached
   to the role, we recommend removing it and attaching it to an IAM role
   that is mapped to the `aws-node` Kubernetes service account instead."*
2. **EKS Pod Identity** (GA late 2023) lets us bind IAM roles to
   `(namespace, service_account)` pairs with a single universal trust
   policy (`pods.eks.amazonaws.com`) — no per-cluster OIDC provider URL,
   no IRSA boilerplate. Most EKS-managed addons (`vpc-cni`,
   `aws-ebs-csi-driver`, `aws-efs-csi-driver`, `aws-fsx-csi-driver`,
   `aws-mountpoint-s3-csi-driver`, `amazon-cloudwatch-observability`,
   `aws-guardduty-agent`, `eks-pod-identity-agent` itself) and every
   well-known community controller (ALB, cert-manager, external-dns,
   external-secrets, Velero, cluster-autoscaler / Karpenter) support
   Pod Identity Associations.

This ADR captures the posture decision. The mechanism — *where* the Pod
Identity Agent addon is installed, *how* associations are wired in
Terraform — is the subject of follow-on ADRs.

## Decision

The EKS node instance role carries only the minimum AWS-managed policies
required for kubelet, kube-proxy, image pulls, and the Pod Identity Agent
to function. Every other AWS credential a workload, controller, or addon
needs is granted via an EKS Pod Identity Association on its specific
Kubernetes service account.

**Mandatory node-role policies:**

| Policy | Why |
|---|---|
| `AmazonEKSWorkerNodePolicy` | kubelet ↔ EKS control plane communication. Also includes `eks-auth:AssumeRoleForPodIdentity` — the permission the Pod Identity Agent uses to vend tokens. No separate policy required for the agent. |
| `AmazonEC2ContainerRegistryPullOnly` | ECR image pulls. More restrictive than the older `AmazonEC2ContainerRegistryReadOnly`. |

**Optional (off by default, toggleable per cluster):**

- `AmazonSSMManagedInstanceCore` — for Session Manager break-glass access
  in lieu of SSH. Off by default; opt in via `var.enable_ssm` on clusters
  that want it.

**Forbidden on the node role:**

- `AmazonEKS_CNI_Policy` → moves to the `aws-node` SA via Pod Identity
  (addons module, ADR-0004).
- `AmazonEBSCSIDriverPolicy` / `AmazonEFSCSIDriverPolicy` /
  `AmazonFSxFullAccess` / Mountpoint-S3 driver policy → move to CSI
  controller SAs via Pod Identity.
- `CloudWatchAgentServerPolicy`, GuardDuty agent policies → move to their
  addon SAs via Pod Identity.
- Inline policies for the workload controllers actually deployed in our
  clusters — each moves to its own per-controller SA via Pod Identity
  Associations (pod-identity-access module). The expected set in this
  fleet:

  | Controller | Notes |
  |---|---|
  | AWS Load Balancer Controller | We consume it via the Kubernetes Gateway API, not Ingress. Same controller, same IAM. |
  | cert-manager | Route 53 DNS-01 challenge access. |
  | external-dns | Route 53 record CRUD scoped to specific zones. |
  | Prometheus stack DaemonSets (node-exporter, kube-state-metrics, prometheus-server) | Mostly Kubernetes-API-only; any CloudWatch / Managed Prometheus remote-write goes on the relevant SA. |
  | Grafana Alloy / Loki | CloudWatch Logs / S3 access for log shipping; Managed Prometheus remote-write for metrics. |
  | Wiz Kubernetes sensor | Per Wiz's published Pod Identity guidance for runtime telemetry. |
  | cluster-autoscaler / Karpenter | ASG describe / SetDesiredCapacity, EC2 describe. |

**End state per cluster:** two managed policies on the node role, zero
inline policies, every controller and addon on its own narrowly-scoped
Pod Identity role.

## Consequences

### Positive

- Blast radius from any node-level compromise — container escape,
  hostNetwork pod, supply-chain CVE in a DaemonSet, SSRF — lands on a
  near-empty role. There is nothing valuable to steal via IMDS.
- Universal Pod Identity trust policy. Every workload role uses the same
  `pods.eks.amazonaws.com` trust statement. The same role is reusable
  across every EKS cluster in the account — no per-cluster OIDC URL, no
  per-cluster trust policy update.
- The hostNetwork-pods-have-IMDS-access concern (which hop-limit policy
  cannot defend against) becomes near-toothless: there are no useful
  credentials at IMDS to begin with. Modern AWS SDKs prefer Pod Identity
  over IMDS in the credential chain anyway, so workloads with Pod
  Identity Associations bypass IMDS entirely.
- AWS-aligned: this is the current official EKS recommendation, not a
  bespoke pattern.
- Composes cleanly with the cross-module remote-state model (ADR-0001).
  Cluster module owns the cluster-wide controller IAM roles; addons
  module owns the Pod Identity Agent install + the addon-level
  associations (ADR-0003); pod-identity-access module owns the
  workload-level associations.

### Negative

- More moving parts at deploy time. Every controller / addon needs an IAM
  role *and* a Pod Identity Association. The pod-identity-access module
  (DESIGN-0004) and addons module (DESIGN-0003) exist specifically to
  manage this multiplication.
- **AWS SDK version trap.** Pre-2023 SDKs do not honor
  `AWS_CONTAINER_CREDENTIALS_FULL_URI` and silently fall back to IMDS.
  Against a minimized node role, that fallback returns near-empty
  credentials and the workload appears to function intermittently — until
  the first IAM call it actually needed. Workloads adopting Pod Identity
  must pin a current SDK base image. There is no Terraform-side check for
  this; it's an operational discipline.
- **Eventual consistency.** Pod Identity Associations are eventually
  consistent — there can be a few-second delay after the API call before
  the agent vends new credentials. Don't create associations in
  critical-path startup code.
- **PrivateLink endpoint requirement.** Nodes in private subnets need a
  VPC endpoint for the EKS Auth API
  (`com.amazonaws.<region>.eks-auth`) for the Pod Identity Agent to
  function. Owned by the VPC stack, not by any module in this repo —
  but a hard dependency to call out in runbooks.
- **Dynamic-namespace workloads.** Pod Identity Associations don't
  accept globs on namespace or service-account names. Per-PR ephemeral
  namespaces need either a per-namespace association created at PR
  spin-up, or a fallback to IRSA for those workloads.

### Neutral

- The IMDS hop-limit policy decision becomes less posture-critical.
  Hop-limit 2 (the EKS managed node group default) is acceptable in
  this design because the node role is empty — that's the durable
  defense, not the hop count. Tightening to hop-limit 1 as
  defense-in-depth is a separate decision (Tier 3 ADR candidate).
- Brownfield migration is workable in place: create the Pod Identity
  Association with the policy set the controller previously inherited
  from the node role; verify the controller picks it up (Pod Identity
  takes precedence over IMDS in the SDK credential chain); then strip
  the node-role attachment.

## Alternatives Considered

**Keep IRSA (IAM Roles for Service Accounts).** The prior pattern, and
still functional. But IRSA requires:

- A per-cluster IAM OIDC provider resource.
- A per-cluster OIDC URL embedded in every workload role's trust policy
  (`oidc.eks.<region>.amazonaws.com/id/<id>:sub` condition keys).
- A workload role that is *not* reusable across clusters — every cluster
  needs its own.

Pod Identity replaces the per-cluster trust dance with one universal
service principal. Less rotation surface, less per-cluster IAM, simpler
cross-cluster role reuse. Pod Identity is strictly the simpler successor
for the cluster types this repo targets (EC2-backed managed node groups).

**Keep policies on the node role; rely on workload sandboxing.** With
gVisor (DESIGN-0001) the syscall surface is restricted, which reduces
some classes of escape. But syscall sandboxing doesn't defend against
hostNetwork pods or against any process that legitimately uses the AWS
SDK from a compromised container. Sandboxing and minimized node IAM are
defense in depth at different layers — complementary, not substitutes.

**One IAM role per node group, scoped to that node group's workload
profile.** Narrower than today's "one giant node role for the fleet,"
but it still bundles every workload on that node group into a shared
role. The cardinality of node-group roles never drops below the number
of distinct workload profiles, and any workload that shares the node
group inherits the union of permissions. The Pod Identity approach
collapses that to one role per workload service account, which is the
actual privilege boundary.

**Hand-roll inline policies on per-workload IAM users.** Doesn't avoid
IMDS exposure (workloads would still have to reach IMDS to assume the
user, or have keys baked in). Strictly worse.

## References

- AWS docs — EKS node IAM role (`AmazonEKS_CNI_Policy` removal
  recommendation):
  <https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html>
- AWS docs — `AmazonEKSWorkerNodePolicy` reference (contains
  `eks-auth:AssumeRoleForPodIdentity`):
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEKSWorkerNodePolicy.html>
- AWS docs — EKS Pod Identity overview:
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
- AWS docs — Pod Identity vs IRSA:
  <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html>
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (the module
  that enforces the minimal node-role property).
- DESIGN-0003 — EKS Addons Module (addon-level associations).
- DESIGN-0004 — EKS Pod Identity Access Module (workload-level
  associations).
- ADR-0003 — Pod Identity Agent on the addons module.
- ADR-0004 (forthcoming) — Addon-managed Pod Identity Association pattern.
