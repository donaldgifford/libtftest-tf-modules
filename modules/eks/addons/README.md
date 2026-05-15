<!-- markdownlint-disable-file MD025 MD041 -->
# EKS Addons Module

Installs the five mandatory EKS managed addons (`eks-pod-identity-agent`,
VPC CNI, kube-proxy, CoreDNS, EBS CSI) plus optional EFS CSI. Implements
[DESIGN-0003](../../../docs/design/0003-eks-addons-module.md).

Per [ADR-0003](../../../docs/adr/0003-eks-pod-identity-agent-addon-installs-first.md)
the Pod Identity Agent is installed first; every other addon in the module
explicitly `depends_on` it. Per [ADR-0004](../../../docs/adr/0004-use-addon-managed-pod-identity-association-block-for-eks-addons.md)
AWS-credentialed addons (VPC CNI, EBS CSI, optional EFS CSI) use the
addon-managed `pod_identity_association` block — the PIA lifecycle is tied
to the addon, not a separate resource.

See [USAGE.md](./USAGE.md) for the generated input / output reference.

## Prerequisites

### PrivateLink endpoint

The Pod Identity Agent reaches the EKS Auth API through the regional
PrivateLink endpoint `com.amazonaws.<region>.eks-auth`. This endpoint
is provisioned by the **VPC stack** (not this module). Without it the
agent will fail to start.

See DESIGN-0003 §Prerequisites and the VPC module's README for endpoint
wiring.

## Cross-stack operational ordering

The fleet's operational order is:

```text
cluster  →  managed-node-group  →  addons  →  pod-identity-access
```

Addon DaemonSets need a schedulable node to reach `ACTIVE`, so the addons
stack is always applied after the node-group stack. The Terraform module
does not enforce this — it is an operational property of the consumer's
Terragrunt configuration. See [CLAUDE.md](../../../CLAUDE.md) §"Pod
Identity Agent lives on the addons module" for the rationale.

## Brownfield migration (existing cluster, IRSA → Pod Identity)

If you are migrating a cluster that already has VPC CNI / EBS CSI / etc.
installed via IRSA annotations, the recommended walk is:

1. Apply this module's `eks-pod-identity-agent` addon first. The agent
   starts running on every node; no existing IRSA bindings break.
2. Apply `aws_eks_addon.vpc_cni` with the addon-managed PIA block. AWS
   handles the cutover atomically: the addon switches from IRSA to PIA
   on the first reconcile. Existing pods continue running on the old
   credentials until they restart.
3. Repeat for `aws_eks_addon.ebs_csi_driver`.
4. Remove the IRSA annotations from the legacy service accounts once you
   confirm pods are picking up the PIA-issued credentials (verify with
   `kubectl get pod <name> -o jsonpath='{.spec.containers[*].env}'`
   looking for `AWS_CONTAINER_CREDENTIALS_FULL_URI`).

The conflict-resolution policy is `OVERWRITE` on create and `PRESERVE`
on update per DESIGN-0003 — your first apply takes ownership of
self-managed addon resources; subsequent applies don't fight cluster
mutators that may have edited the addon CRD spec.

## Addon version resolution

Every addon's version variable (`var.pod_identity_agent_version`,
`var.vpc_cni_version`, etc.) defaults to `null`. Null routes to
`data.aws_eks_addon_version.<name>` with `most_recent = true` — the
AWS-idiomatic "latest compatible with the cluster's Kubernetes version"
pick. Set a non-null literal to pin a specific version for supply-chain
control (e.g. CI promotion gating).

The cluster's K8s version is read from the cluster module's remote-state
output `cluster_version` per [ADR-0001](../../../docs/adr/0001-use-data-terraform-remote-state-for-cross-module-composition.md).

[Usage docs](./USAGE.md)
