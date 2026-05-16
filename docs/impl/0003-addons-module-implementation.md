---
id: IMPL-0003
title: "Addons Module Implementation"
status: Completed
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0003: Addons Module Implementation

**Status:** Completed
**Author:** Donald Gifford
**Date:** 2026-05-15

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Variable surface and module skeleton](#phase-1-variable-surface-and-module-skeleton)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Pod Identity Agent addon (first, no IAM)](#phase-2-pod-identity-agent-addon-first-no-iam)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: VPC CNI addon with addon-managed PIA](#phase-3-vpc-cni-addon-with-addon-managed-pia)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: kube-proxy and CoreDNS addons (no IAM)](#phase-4-kube-proxy-and-coredns-addons-no-iam)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: EBS CSI addon with addon-managed PIA](#phase-5-ebs-csi-addon-with-addon-managed-pia)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: EFS CSI addon (gated)](#phase-6-efs-csi-addon-gated)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: Addon version resolution data sources](#phase-7-addon-version-resolution-data-sources)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: Outputs and USAGE.md generation](#phase-8-outputs-and-usagemd-generation)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 9: terraform test plan-only suite (tests/)](#phase-9-terraform-test-plan-only-suite-tests)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
  - [Phase 10: terraform test apply-LocalStack suite (tests-localstack/)](#phase-10-terraform-test-apply-localstack-suite-tests-localstack)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — Shared Pod Identity trust policy location](#q1--shared-pod-identity-trust-policy-location)
  - [Q2 — cluster_version missing from cluster module outputs](#q2--clusterversion-missing-from-cluster-module-outputs)
  - [Q3 — Default for podidentityagent_version](#q3--default-for-podidentityagentversion)
  - [Q4 — LocalStack data.awseksaddon_version fidelity](#q4--localstack-dataawseksaddonversion-fidelity)
  - [Q5 — PrivateLink endpoint testing](#q5--privatelink-endpoint-testing)
  - [Q6 — configuration_values JSON testing](#q6--configurationvalues-json-testing)
- [References](#references)
<!--toc:end-->

## Objective

Implement the EKS addons module per DESIGN-0003 — installs the five
mandatory EKS managed addons (`eks-pod-identity-agent`, VPC CNI,
kube-proxy, CoreDNS, EBS CSI) plus optional EFS CSI, with the agent
applied **first** and every other addon explicitly `depends_on` it per
ADR-0003. The AWS-credentialed addons use the addon-managed
`pod_identity_association` block pattern per ADR-0004 — the
association lifecycle is tied to the addon, not a separate resource.

**Implements:** DESIGN-0003 — EKS Addons Module.

**Constrained by:** ADR-0001 (remote-state composition), ADR-0002
(node IAM minimization — this module is where the CSI/CNI policies
re-home to per-addon Pod Identity roles), ADR-0003 (Pod Identity Agent
lives here, first), ADR-0004 (addon-managed PIA pattern), ADR-0011
(AWS-API-only Terraform).

**Constrained by:** RFC-0001 — `terraform test` is the default
framework. Apply-time runtime invariants (e.g., DaemonSet readiness)
are the canonical libtftest migration trigger — they cannot be
expressed in HCL `assert`. When the libtftest harness covers
`aws_eks_addon` apply against kind/k3d, this module is the strongest
migration candidate in the fleet.

## Scope

### In Scope

- `aws_eks_addon.eks_pod_identity_agent` — applied first, **no
  `depends_on`**, no IAM role, no PIA block (the agent uses
  `eks-auth:AssumeRoleForPodIdentity` from the node role's
  `AmazonEKSWorkerNodePolicy`).
- `aws_eks_addon.vpc_cni` with addon-managed PIA: IAM role trusting
  `pods.eks.amazonaws.com`, `AmazonEKS_CNI_Policy` attachment, PIA
  binding to `aws-node` SA in `kube-system`.
- `aws_eks_addon.kube_proxy` and `aws_eks_addon.coredns` — no IAM,
  but `depends_on` the agent for graph regularity.
- `aws_eks_addon.ebs_csi_driver` with addon-managed PIA: IAM role
  trusting `pods.eks.amazonaws.com`, `AmazonEBSCSIDriverPolicy`
  attachment, PIA binding to `ebs-csi-controller-sa` SA.
- `aws_eks_addon.efs_csi_driver[0]` + IAM/PIA, gated on
  `var.efs_csi_enabled` (default `false`).
- Addon version resolution: `var.<name>_version = null` → resolve
  latest via `data.aws_eks_addon_version`.
- `resolve_conflicts_on_create = "OVERWRITE"`, `_on_update = "PRESERVE"`
  per DESIGN-0003 §"Conflict resolution".
- Cross-module composition via remote state per ADR-0001.
- `terraform test` plan-only suite in `tests/`.
- `terraform test` apply-LocalStack suite in `tests-localstack/`
  surfacing addon coverage gaps in LocalStack Pro EKS.
- USAGE.md via terraform-docs.

### Out of Scope

- Workload controllers (cert-manager, external-dns, ALB controller,
  cluster-autoscaler, FluentD, CW metrics) — those use the
  pod-identity-access module (DESIGN-0004 / IMPL-0004).
- The CoreDNS-as-DaemonSet (NodeLocal DNSCache) variant — deferred per
  DESIGN-0003 §Open Questions.
- A typed input for CoreDNS replica configuration — v1 uses free-form
  `configuration_values`.
- Provisioning the VPC's `com.amazonaws.<region>.eks-auth` endpoint —
  VPC stack owns it; module README documents it as a prerequisite.
- DaemonSet-ready / addon-status runtime validation — needs libtftest
  + kind/k3d bridge per RFC-0001 §Phase 3; not catchable in
  `terraform test` against LocalStack alone.

## Implementation Phases

Each phase builds on the previous. A phase is complete when all its
tasks are checked off and its success criteria are met.

---

### Phase 1: Variable surface and module skeleton

Establish the module directory, variables, versions, data sources.
No resources yet.

#### Tasks

- [x] Create `modules/eks/addons/` with standard scaffolding files.
- [x] `versions.tf`: terraform >= 1.1, aws ~> 6.2.
- [x] `variables.tf`:
      - Required: `remote_state_bucket`, `region`, `cluster_name`,
        `pod_identity_agent_version` (no default per ADR-0003).
      - Optional: `vpc_cni_version`, `vpc_cni_configuration_values`,
        `kube_proxy_version`, `coredns_version`,
        `coredns_configuration_values`, `ebs_csi_version`,
        `efs_csi_enabled` (default `false`), `efs_csi_version`,
        `tags` (typed object similar to cluster module).
- [x] `data.tf`: `data.terraform_remote_state.eks` with
      `use_path_style = true`.
- [x] `.terraform-docs.yml`, `.tflint.hcl`, `README.md` (placeholder),
      `USAGE.md` (placeholder).
- [x] `terraform validate` clean.

#### Success Criteria

- `terraform validate` passes with no resources defined.
- `terraform fmt -check -recursive` clean.
- `tflint` clean.
- Validation on `pod_identity_agent_version`: empty string rejected
  (forces caller to pin).

---

### Phase 2: Pod Identity Agent addon (first, no IAM)

Per ADR-0003, this is the first thing the module installs.

#### Tasks

- [x] `pod_identity_agent.tf`: `aws_eks_addon.eks_pod_identity_agent`.
- [x] `cluster_name = data.terraform_remote_state.eks.outputs.cluster_name`.
- [x] `addon_name = "eks-pod-identity-agent"`.
- [x] `addon_version = var.pod_identity_agent_version`.
- [x] `resolve_conflicts_on_create = "OVERWRITE"`.
- [x] `resolve_conflicts_on_update = "PRESERVE"`.
- [x] **No** `pod_identity_association` block (agent uses node-role
      `eks-auth:AssumeRoleForPodIdentity` per ADR-0002 / ADR-0003).
- [x] **No** `aws_iam_role` for the agent.
- [x] `tags = var.tags`.
- [x] Add a header comment to `pod_identity_agent.tf` documenting
      that this addon is the foundation every other addon
      `depends_on` per ADR-0003.

#### Success Criteria

- `terraform validate` clean.
- Plan shows exactly one `aws_eks_addon` resource (the agent).
- Plan shows no `aws_iam_role` resources.
- The agent resource has no `depends_on` argument (it is the root).

---

### Phase 3: VPC CNI addon with addon-managed PIA

The CSI/CNI policies re-home from the node role to per-addon Pod
Identity roles per ADR-0002. This is the first instance of that
pattern.

#### Tasks

- [x] `vpc_cni.tf`:
      - `data.aws_iam_policy_document.pod_identity_trust` —
        `pods.eks.amazonaws.com` with
        `["sts:AssumeRole", "sts:TagSession"]`. Shared by all
        addons in this module; lives in this file or a shared
        `locals.tf` / `iam.tf` — see Open Question Q1.
      - `aws_iam_role.vpc_cni` named
        `${cluster_name}-vpc-cni` (truncated to ≤ 64 chars).
      - `aws_iam_role_policy_attachment.vpc_cni` →
        `AmazonEKS_CNI_Policy`.
      - `aws_eks_addon.vpc_cni`:
        - `addon_name = "vpc-cni"`.
        - `addon_version` resolves via Phase 7's
          `data.aws_eks_addon_version.vpc_cni` when
          `var.vpc_cni_version` is null.
        - `configuration_values = var.vpc_cni_configuration_values`.
        - Conflict resolution: OVERWRITE/PRESERVE.
        - `pod_identity_association { service_account = "aws-node"; role_arn = aws_iam_role.vpc_cni.arn }`.
        - `depends_on = [aws_eks_addon.eks_pod_identity_agent]`.

#### Success Criteria

- `terraform validate` clean.
- Plan shows the VPC CNI addon with exactly one
  `pod_identity_association` block (service_account = "aws-node").
- VPC CNI IAM role has exactly one managed policy attached
  (`AmazonEKS_CNI_Policy`).
- VPC CNI addon `depends_on` references the agent addon.

---

### Phase 4: kube-proxy and CoreDNS addons (no IAM)

Both addons operate against the Kubernetes API only; no AWS
credentials needed. Per DESIGN-0003 they still `depends_on` the agent
to keep the dependency graph regular.

#### Tasks

- [x] `main.tf`: `aws_eks_addon.kube_proxy` and
      `aws_eks_addon.coredns`.
- [x] Both with `addon_version` (null → resolved via Phase 7),
      conflict resolution OVERWRITE/PRESERVE, `depends_on =
      [aws_eks_addon.eks_pod_identity_agent]`, `tags = var.tags`.
- [x] CoreDNS: `configuration_values = var.coredns_configuration_values`.
- [x] Neither addon has a `pod_identity_association` block.

#### Success Criteria

- `terraform validate` clean.
- Plan shows kube-proxy and coredns addons with no IAM resources.
- Both `depends_on` the agent addon.

---

### Phase 5: EBS CSI addon with addon-managed PIA

Mirror of Phase 3 for EBS CSI.

#### Tasks

- [x] `ebs_csi.tf`:
      - `aws_iam_role.ebs_csi` named `${cluster_name}-ebs-csi`.
      - `aws_iam_role_policy_attachment.ebs_csi` →
        `AmazonEBSCSIDriverPolicy`.
      - `aws_eks_addon.ebs_csi_driver` with:
        - `addon_name = "aws-ebs-csi-driver"`.
        - `pod_identity_association { service_account = "ebs-csi-controller-sa"; role_arn = aws_iam_role.ebs_csi.arn }`.
        - `depends_on = [aws_eks_addon.eks_pod_identity_agent]`.

#### Success Criteria

- `terraform validate` clean.
- Plan shows the EBS CSI addon with the expected PIA block.
- EBS CSI IAM role has exactly one managed policy attached
  (`AmazonEBSCSIDriverPolicy`).
- EBS CSI addon `depends_on` references the agent addon.

---

### Phase 6: EFS CSI addon (gated)

Behind `var.efs_csi_enabled` (default `false`).

#### Tasks

- [x] `efs_csi.tf` with `count = var.efs_csi_enabled ? 1 : 0` on
      every resource:
      - `aws_iam_role.efs_csi[0]`.
      - `aws_iam_role_policy_attachment.efs_csi[0]` →
        `AmazonEFSCSIDriverPolicy`.
      - `aws_eks_addon.efs_csi_driver[0]` with PIA binding to
        `efs-csi-controller-sa` SA, `depends_on` the agent.

#### Success Criteria

- `terraform validate` clean.
- Plan with `efs_csi_enabled = false` shows zero EFS resources.
- Plan with `efs_csi_enabled = true` shows the addon, role, attachment,
  and PIA block (with the agent depended on).

---

### Phase 7: Addon version resolution data sources

For each addon whose version variable is `null`, resolve the latest
compatible version against the cluster's K8s version.

#### Tasks

- [x] `data.aws_eks_addon_version.vpc_cni` with `addon_name = "vpc-cni"`,
      `kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version`.
      **See Open Question Q2 — cluster_version is not currently
      output by the cluster module; needs to be added before this
      phase begins.**
- [x] Similar data sources for kube-proxy, coredns, aws-ebs-csi-driver,
      aws-efs-csi-driver (gated).
- [x] Replace direct `var.<name>_version` references in each addon
      with `coalesce(var.<name>_version, data.aws_eks_addon_version.<name>.version)`.

#### Success Criteria

- `terraform validate` clean.
- With all `*_version` vars null, plan resolves a non-null
  `addon_version` value for every addon.
- With one explicit pin (e.g., `vpc_cni_version = "v1.18.0-eksbuild.1"`),
  plan uses the pinned value and ignores the data source.

---

### Phase 8: Outputs and USAGE.md generation

#### Tasks

- [x] `outputs.tf`:
      - `pod_identity_agent_addon_arn`.
      - `pod_identity_agent_addon_id`.
      - `vpc_cni_role_arn`.
      - `ebs_csi_role_arn`.
      - `efs_csi_role_arn` (null when disabled).
      - `addon_versions` map.
- [x] `terraform-docs .` regenerates `USAGE.md`.
- [x] `README.md` documents:
      - PrivateLink endpoint prerequisite (`com.amazonaws.<region>.eks-auth`).
      - Cross-stack operational ordering (cluster → nodes → addons →
        pod-identity-access).
      - Brownfield migration walk per DESIGN-0003 §Migration.

#### Success Criteria

- `terraform validate` clean.
- `terraform-docs .` produces a non-empty USAGE.md.
- Plan declares all 6 outputs.

---

### Phase 9: terraform test plan-only suite (tests/)

#### Tasks

- [x] `tests/default.tftest.hcl`:
      - `override_data` for `data.terraform_remote_state.eks`, the
        five `data.aws_eks_addon_version.*`, and
        `data.aws_caller_identity.current`.
      - Set `pod_identity_agent_version = "v1.3.0-eksbuild.1"`.
      - Assertions:
        - Exactly 5 `aws_eks_addon` resources (agent + 4 mandatory),
          0 EFS.
        - Agent addon has no `depends_on`.
        - Every non-agent addon has `depends_on` including
          `aws_eks_addon.eks_pod_identity_agent` — **most load-bearing
          assertion in the suite** per DESIGN-0003.
        - VPC CNI addon has `pod_identity_association` with
          `service_account == "aws-node"`.
        - EBS CSI addon has `pod_identity_association` with
          `service_account == "ebs-csi-controller-sa"`.
        - Agent addon has zero `pod_identity_association` blocks.
        - VPC CNI role has `AmazonEKS_CNI_Policy` attached only.
        - EBS CSI role has `AmazonEBSCSIDriverPolicy` attached only.
        - Each IAM role's trust policy includes
          `pods.eks.amazonaws.com` with
          `sts:AssumeRole`+`sts:TagSession`.
- [x] `tests/efs_csi_enabled.tftest.hcl`:
      - With `efs_csi_enabled = true`, plan adds 1 addon, 1 IAM role,
        1 policy attachment, 1 PIA block.
- [x] `tests/version_resolution.tftest.hcl`:
      - With `vpc_cni_version = "v1.18.0-eksbuild.1"`, addon's
        resolved version is the pinned literal.
      - With `vpc_cni_version = null`, addon's resolved version
        comes from `data.aws_eks_addon_version.vpc_cni.version`.
- [x] `tests/agent_version_required.tftest.hcl`:
      - `pod_identity_agent_version = ""` rejected at variable
        validation.

#### Success Criteria

- `just tf test eks/addons` passes in <5s with no LocalStack.
- All DESIGN-0003 §Testing Strategy plan-time assertions covered.

---

### Phase 10: terraform test apply-LocalStack suite (tests-localstack/)

The gap-discovery mode per RFC-0001. This module is one of the most
interesting LocalStack-coverage probes in the fleet — every addon
plus the addon-managed PIA pattern.

#### Tasks

- [x] `tests-localstack/fixtures/setup/`: VPC + subnets + S3 bucket +
      stub `eks` remote state.
- [x] `tests-localstack/apply_localstack.tftest.hcl`:
      - Provider config with LocalStack endpoints.
      - `command = apply` for setup, then for the addons module.
      - Assertions on returned values:
        - `aws_eks_addon.eks_pod_identity_agent.arn` populated.
        - `aws_iam_role.vpc_cni.arn` populated.
        - `aws_iam_role.ebs_csi.arn` populated.
        - `aws_eks_addon.vpc_cni.pod_identity_association` registered.
        - `aws_eks_addon.ebs_csi_driver.pod_identity_association` registered.
- [x] Document inline findings — likely:
      - Whether LocalStack Pro accepts the addon-managed
        `pod_identity_association` block (newer EKS API).
      - Whether the agent addon's apply succeeds in LocalStack
        (eks-pod-identity-agent is listed as "available" in /info;
        depth unknown).
      - Whether `data.aws_eks_addon_version` resolves against
        LocalStack (this lookup queries AWS's published addon
        catalog — possibly stubbed/empty in LocalStack).
- [x] If `data.aws_eks_addon_version` returns empty in LocalStack,
      use literal version pins in the apply test variables and
      document the LocalStack gap inline.

#### Success Criteria

- `just tf test-localstack eks/addons` passes against LocalStack Pro,
  or every failure is documented as a named sneakystack ticket.
- Every documented gap cites a specific tftest.hcl `run` block per
  RFC-0001's "no speculative tickets" rule.

---

## File Changes

| File                                                | Action | Description                                                                  |
| --------------------------------------------------- | ------ | ---------------------------------------------------------------------------- |
| `modules/eks/addons/versions.tf`                    | Create | tf >= 1.1, aws ~> 6.2                                                        |
| `modules/eks/addons/variables.tf`                   | Create | Required + optional inputs                                                   |
| `modules/eks/addons/locals.tf`                      | Create | Shared trust policy doc reference                                            |
| `modules/eks/addons/data.tf`                        | Create | terraform_remote_state.eks + 5 aws_eks_addon_version data sources            |
| `modules/eks/addons/iam.tf`                         | Create | Shared `data.aws_iam_policy_document.pod_identity_trust` (per Q1)            |
| `modules/eks/addons/pod_identity_agent.tf`          | Create | Phase 2                                                                      |
| `modules/eks/addons/vpc_cni.tf`                     | Create | Phase 3                                                                      |
| `modules/eks/addons/main.tf`                        | Create | Phase 4 (kube-proxy + coredns)                                               |
| `modules/eks/addons/ebs_csi.tf`                     | Create | Phase 5                                                                      |
| `modules/eks/addons/efs_csi.tf`                     | Create | Phase 6 (gated)                                                              |
| `modules/eks/addons/outputs.tf`                     | Create | Phase 8                                                                      |
| `modules/eks/addons/README.md`                      | Create | Prerequisites + migration guide                                              |
| `modules/eks/addons/USAGE.md`                       | Regen  | terraform-docs                                                               |
| `modules/eks/addons/.terraform-docs.yml`            | Create | Copy from cluster                                                            |
| `modules/eks/addons/.tflint.hcl`                    | Create | Copy from cluster                                                            |
| `modules/eks/addons/tests/`                         | Create | Phase 9 plan-only suite                                                      |
| `modules/eks/addons/tests-localstack/`              | Create | Phase 10 apply-LocalStack suite                                              |

## Testing Plan

- [x] `terraform validate` clean after each phase.
- [x] `tflint` clean after each phase.
- [x] `terraform fmt -check -recursive` clean.
- [x] `terraform-docs .` produces a non-empty USAGE.md after Phase 8.
- [x] `just tf test eks/addons` — plan-only suite passes.
- [x] `just tf test-localstack eks/addons` — apply-LocalStack passes
      or every gap is documented as a named ticket.
- [x] Post-deploy validation (`kubectl -n kube-system get pods`,
      addons `Running`) — out of scope here; lives on the
      Terragrunt-unit layer in infrastructure-live.

## Dependencies

- **IMPL-0001 merged** — cluster module's remote-state contract.
  (Already merged.) **But: requires the cluster module to ALSO output
  `cluster_version` per Open Question Q2** — small follow-up.
- **IMPL-0002 not strictly required** — addons reads cluster state,
  not node-group state. However, addon DaemonSets need schedulable
  nodes to reach `ACTIVE` in real EKS, so consumer Terragrunt stacks
  instantiate this AFTER managed-node-group. The Terraform module
  doesn't enforce this; it's an operational ordering in the README.
- **mise toolchain** — Terraform, terraform-docs, tflint, just; AWS
  provider 6.2+; LocalStack Pro 2026.x for Phase 10.

## Open Questions

All resolved 2026-05-15.

### Q1 — Shared Pod Identity trust policy location

**Resolved B.** Single shared
`data "aws_iam_policy_document" "pod_identity_trust"` in `locals.tf`,
referenced by VPC CNI / EBS CSI / EFS CSI addon blocks. One block,
three references. A dedicated `iam.tf` for one data source is sub-module
ceremony for no real gain. Phase 1 task list updates: add the trust
policy data source to `locals.tf` (not `iam.tf` as DESIGN-0003 originally
suggested).

### Q2 — `cluster_version` missing from cluster module outputs

**Resolved A (already implemented in this branch).** `cluster_version`
added to `modules/eks/cluster/outputs.tf` as
`output "cluster_version" { value = aws_eks_cluster.this.version }`,
and asserted by `modules/eks/cluster/tests/default.tftest.hcl` to
mirror the upstream resource attribute. CLAUDE.md's "Outputs (remote-
state contract)" line is updated. IMPL-0003's Phase 7 (Addon version
resolution) consumes
`data.terraform_remote_state.eks.outputs.cluster_version` at the use
site (ADR-0001 — no aliasing local).

### Q3 — Default for `pod_identity_agent_version`

**Resolved C with override.** Default to
`data.aws_eks_addon_version.pod_identity_agent` with
`most_recent = true` — the AWS-idiomatic pattern, gives plan-time
determinism without hardcoding. Allow explicit override via
`var.pod_identity_agent_version`: when non-null, the addon resource
uses the literal; when null, it uses the data-source resolved value.
Captures the "preferred idiomatic AWS way as default; explicit pin
available for supply-chain control" posture. Same shape applied to
every addon-version input (VPC CNI, kube-proxy, CoreDNS, EBS CSI, EFS
CSI) for consistency.

### Q4 — LocalStack `data.aws_eks_addon_version` fidelity

**Resolved A.** Test in Phase 10 and capture findings — proceed
regardless. If the catalog is empty, Phase 10 test fixtures pin literal
versions for the affected runs and `FINDINGS.md` files a sneakystack
ticket for "populate `describe-addon-versions` catalog response."

### Q5 — PrivateLink endpoint testing

**Resolved A.** `com.amazonaws.<region>.eks-auth` is a VPC-stack
concern; document as a prerequisite in the module's README. Not
provisioned by this module. Not exercised in Phase 10.

### Q6 — `configuration_values` JSON testing

**Resolved C.** Don't test the freeform passthrough — `configuration_values`
is caller-controlled JSON; testing that "what was passed in is what
shows up in the plan" is uninteresting. Assert only that any
module-provided **defaults** (if a phase ships one) parse as valid JSON.
This is the exact gap RFC-0001 is meant to surface: any future need
to validate addon configuration semantics against the live API
becomes a libtftest backlog item (apply-time runtime invariant
against a kind/k3d cluster fronted by sneakystack). Captured in
`FINDINGS.md` as a libtftest candidate.

## References

- [DESIGN-0003: EKS Addons Module](../design/0003-eks-addons-module.md)
- [DESIGN-0001](../design/0001-secure-eks-managed-node-group-with-gvisor.md), [DESIGN-0002](../design/0002-eks-cluster-module.md), [DESIGN-0004](../design/0004-eks-pod-identity-access-module.md) — sibling designs.
- [IMPL-0001: EKS Cluster Module Implementation](0001-eks-cluster-module-implementation.md) — provides the remote state this module reads.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) / [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) / [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — testing strategy.
- ADRs 0001, 0002, 0003, 0004, 0011 — constraining this module.
