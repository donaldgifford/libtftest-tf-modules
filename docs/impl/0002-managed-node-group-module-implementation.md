---
id: IMPL-0002
title: "Managed Node Group Module Implementation"
status: Draft
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0002: Managed Node Group Module Implementation

**Status:** Draft
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
  - [Phase 2: Node IAM role and instance profile](#phase-2-node-iam-role-and-instance-profile)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Launch template (hardening + KMS-encrypted EBS)](#phase-3-launch-template-hardening--kms-encrypted-ebs)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: User data template (AL2023 + gVisor install)](#phase-4-user-data-template-al2023--gvisor-install)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: awseksnode_group resource](#phase-5-awseksnodegroup-resource)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Outputs and USAGE.md generation](#phase-6-outputs-and-usagemd-generation)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: terraform test plan-only suite (tests/)](#phase-7-terraform-test-plan-only-suite-tests)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: terraform test apply-LocalStack suite (tests-localstack/)](#phase-8-terraform-test-apply-localstack-suite-tests-localstack)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — Module-scaffolding distribution mechanism](#q1--module-scaffolding-distribution-mechanism)
  - [Q2 — gVisor SHA-512 verification source](#q2--gvisor-sha-512-verification-source)
  - [Q3 — Kubelet-join LocalStack fidelity in Phase 8](#q3--kubelet-join-localstack-fidelity-in-phase-8)
  - [Q4 — gVisor systrap on arm64](#q4--gvisor-systrap-on-arm64)
  - [Q5 — Renovate pinning UX](#q5--renovate-pinning-ux)
  - [Q6 — var.extranodepolicies for opt-in ECR pull-through policy](#q6--varextranodepolicies-for-opt-in-ecr-pull-through-policy)
  - [Q7 — Containerd pull-through registry mirror in user data](#q7--containerd-pull-through-registry-mirror-in-user-data)
- [References](#references)
<!--toc:end-->

## Objective

Implement the secure managed node group module per DESIGN-0001 — a
reusable EKS managed-node-group module that provisions AL2023 nodes
with minimal IAM (ADR-0002), IMDSv2 + hop-limit 2 (ADR-0007), gVisor
syscall sandboxing (ADR-0005), and architecture-pinned scheduling
(ADR-0006). The module is the second module in the fleet after the
cluster module; it consumes the cluster's remote-state outputs and
emits a node-IAM-role-arn + nodegroup-name contract that downstream
addon and pod-identity-access modules can read.

**Implements:** DESIGN-0001 — Secure EKS Managed Node Group with
gVisor.

**Constrained by:** ADR-0001 (remote-state composition), ADR-0002
(minimal node IAM), ADR-0005 (gVisor runtime), ADR-0006 (ARM64
default), ADR-0007 (IMDS hop=2), ADR-0008 (AL2023 only), ADR-0009
(ON_DEMAND default), ADR-0010 (gVisor release pinning), ADR-0011
(RuntimeClass out-of-band), ADR-0012 (SSM opt-in).

**Constrained by:** RFC-0001 — `terraform test` is the default
framework for this module. libtftest is not used. The migration
trigger from RFC-0001 governs any future move to libtftest (e.g., if
kubelet-join validation needs the kind/k3d bridge).

## Scope

### In Scope

- `aws_iam_role.node` + `aws_iam_instance_profile.node` with exactly
  `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly`
  attached; `AmazonSSMManagedInstanceCore` gated on `var.enable_ssm`
  per ADR-0012.
- `aws_launch_template.node` with IMDSv2 required, hop limit 2, EBS
  KMS-encrypted with the cluster module's KMS key (read from remote
  state).
- AL2023-shaped user data template that installs and configures gVisor
  (downloads `runsc` + shim, verifies SHA-512, writes containerd
  drop-ins, restarts containerd).
- `aws_eks_node_group.this` with arch-pinned `ami_type`, `ON_DEMAND`
  capacity default, `workload-class=secure:NO_SCHEDULE` taint,
  arch + runtime labels.
- Cross-module composition via remote state (cluster + VPC) per
  ADR-0001.
- `terraform test` plan-only suite in `tests/` covering the plan-time
  invariants from DESIGN-0001 §Testing Strategy.
- `terraform test` apply-LocalStack suite in `tests-localstack/`
  exercising IAM, launch template, and node group resource creation
  to surface LocalStack coverage gaps per RFC-0001.
- USAGE.md regenerated via terraform-docs.

### Out of Scope

- Creating the gVisor `RuntimeClass` Kubernetes manifest — out-of-band
  delivery per ADR-0011. The module's README documents the manifest
  shape; this IMPL does not provision it.
- The Pod Identity Agent or any addon — DESIGN-0003 / IMPL-0003.
- Workload-level Pod Identity Associations — DESIGN-0004 / IMPL-0004.
- Bottlerocket variant (deferred per DESIGN-0001 §Open Questions).
- GPU node groups, Spot fleets with mixed instance policies.
- Runtime-validation of "node joins kubelet" — that needs the libtftest
  + kind/k3d bridge per RFC-0001 §Phase 3 and is not yet capable. The
  apply-LocalStack tests validate AWS API resource creation only.

## Implementation Phases

Each phase builds on the previous. A phase is complete when all its
tasks are checked off and its success criteria are met.

---

### Phase 1: Variable surface and module skeleton

Establish the module directory, variable surface, versions.tf, and
remote-state data sources. No resources are created yet; the goal is
that `terraform validate` passes against a fully-typed but
resource-free configuration.

#### Tasks

- [x] Create `modules/eks/managed-node-group/` with the standard
      scaffolding: `versions.tf`, `variables.tf`, `locals.tf`,
      `data.tf`, `main.tf`, `outputs.tf`, `README.md`, `USAGE.md`
      (placeholder), `.terraform-docs.yml`, `.tflint.hcl`.
- [x] `versions.tf`: `terraform >= 1.1`, `hashicorp/aws ~> 6.2`.
- [x] `variables.tf`: required inputs (`remote_state_bucket`,
      `region`, `cluster_name`, `vpc_name`, `nodegroup_name`) and
      typed optionals (`architecture` object per DESIGN-0001 with
      validation, `instance_types`, `capacity_type`, `desired_size`/
      `min_size`/`max_size`, `disk_size_gib`, `enable_ssm`,
      `gvisor_release`, `additional_labels`, `additional_taints`,
      `extra_kubelet_args`, `tags`).
- [x] `data.tf`: `data.terraform_remote_state.eks` + `.vpc` with
      `use_path_style = true` per cluster module's drive-by fix.
- [x] `locals.tf`: minimal — `local.runtime_labels` (the
      `runtime=gvisor`, `workload-class=secure` standard label pair
      merged with `var.additional_labels`).
- [x] `main.tf`: header comment only at this phase.
- [x] `outputs.tf`: empty at this phase; finalized in Phase 6.
- [x] `.tflint.hcl`: copy from cluster module.
- [x] `.terraform-docs.yml`: copy from cluster module.
- [x] `terraform init -backend=false && terraform validate` clean.

#### Success Criteria

- `terraform validate` passes with no resources defined.
- Variable validation works: `architecture.name = "x86"` rejected,
  `architecture.name = "arm64"` accepted.
- `terraform fmt -check -recursive` clean.
- `tflint --init && tflint` clean (no false positives from the empty
  module).

---

### Phase 2: Node IAM role and instance profile

Land the minimal node IAM per ADR-0002 with the SSM opt-in per
ADR-0012.

#### Tasks

- [x] `iam.tf`: `data.aws_iam_policy_document.node_assume_role`
      trusting `ec2.amazonaws.com`.
- [x] `aws_iam_role.node` named `${var.nodegroup_name}-node`.
- [x] `aws_iam_role_policy_attachment.worker_node` →
      `AmazonEKSWorkerNodePolicy`.
- [x] `aws_iam_role_policy_attachment.ecr_pull_only` →
      `AmazonEC2ContainerRegistryPullOnly`.
- [x] `aws_iam_role_policy_attachment.ssm[0]` →
      `AmazonSSMManagedInstanceCore`, gated on `var.enable_ssm`.
- [x] `aws_iam_instance_profile.node` bound to `aws_iam_role.node`.

#### Success Criteria

- `terraform validate` clean.
- `tflint` clean.
- A plan with `enable_ssm = false` shows exactly two
  `aws_iam_role_policy_attachment` resources.
- A plan with `enable_ssm = true` shows three.
- No `AmazonEKS_CNI_Policy`, `AmazonEBSCSIDriverPolicy`,
  `CloudWatchAgentServerPolicy`, or inline workload policies are
  referenced anywhere in the module.

---

### Phase 3: Launch template (hardening + KMS-encrypted EBS)

Land the launch template per DESIGN-0001 §"Launch template hardening".
User data is wired in Phase 4 — this phase wires everything except
the rendered user data body.

#### Tasks

- [x] `launch_template.tf`: `aws_launch_template.node`.
- [x] `metadata_options`: `http_tokens = "required"`,
      `http_put_response_hop_limit = 2`,
      `instance_metadata_tags = "enabled"` (per ADR-0007).
- [x] `block_device_mappings` for the root volume: `gp3`,
      `encrypted = true`, `kms_key_id` from
      `data.terraform_remote_state.eks.outputs.kms_key_arn`,
      `delete_on_termination = true`, `volume_size = var.disk_size_gib`.
- [x] `monitoring { enabled = true }`.
- [x] `vpc_security_group_ids = [data.terraform_remote_state.eks.outputs.node_security_group_id]`.
- [x] `iam_instance_profile { arn = aws_iam_instance_profile.node.arn }`.
- [x] `tag_specifications` for `instance` and `volume`.
- [x] `lifecycle { create_before_destroy = true }`.
- [x] `user_data` is a placeholder for Phase 4
      (`base64encode("placeholder")` so plan succeeds).

#### Success Criteria

- `terraform validate` clean.
- Plan shows `aws_launch_template.node.metadata_options[0].http_tokens
  == "required"` and `http_put_response_hop_limit == 2`.
- Plan shows `block_device_mappings[0].ebs[0].encrypted == true`.
- Plan shows the KMS key ARN read from remote state, not hardcoded.

---

### Phase 4: User data template (AL2023 + gVisor install)

Land the multipart MIME user data per DESIGN-0001 §"User data
(multipart MIME)" and ADR-0005 / ADR-0008 / ADR-0010.

#### Tasks

- [x] `templates/user_data.sh.tftpl` — AL2023 nodeadm bootstrap +
      gVisor install + containerd drop-in.
- [x] Template variables: `cluster_name`, `cluster_endpoint`,
      `cluster_ca_data`, `gvisor_arch` (derived from
      `var.architecture`), `gvisor_release`, `extra_kubelet_args`.
- [x] gVisor download flow: `runsc` + `containerd-shim-runsc-v1`
      from `https://storage.googleapis.com/gvisor/releases/<release>/<arch>`,
      SHA-512 verification using upstream-published hashes.
- [x] containerd drop-in at `/etc/containerd/config.d/runsc.toml`
      registering the `runsc` runtime handler.
- [x] `/etc/containerd/runsc.toml` with `platform = "systrap"`,
      `network = "sandbox"` per ADR-0005.
- [x] containerd restart + assertion that the `runsc` plugin is
      loaded.
- [x] `user_data.tf`: `templatefile(...)` invocation wired into
      `aws_launch_template.node.user_data` (replacing the Phase 3
      placeholder).
- [x] Document the GoogleAPIs storage release URL pattern + Renovate
      bump policy in the user data file's header comment.

#### Success Criteria

- `terraform validate` clean.
- Plan shows `user_data` (base64-encoded) rendered with the expected
  cluster endpoint and version values from remote state.
- Decoded user data inspectable via `terraform show -json plan.bin`
  contains the gVisor install steps and the containerd drop-in.
- Renaming `var.gvisor_release` produces a different rendered body
  (deterministic).

---

### Phase 5: aws_eks_node_group resource

Land the node group resource per DESIGN-0001 §"EKS node group".

#### Tasks

- [x] `main.tf`: `aws_eks_node_group.this`.
- [x] `cluster_name = data.terraform_remote_state.eks.outputs.cluster_name`.
- [x] `node_role_arn = aws_iam_role.node.arn`.
- [x] `subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids`.
- [x] `ami_type = var.architecture.ami_type`.
- [x] `instance_types = length(var.instance_types) > 0 ? var.instance_types : var.architecture.default_instance_types`.
- [x] `capacity_type = var.capacity_type` (default `ON_DEMAND`).
- [x] `scaling_config` with `desired_size`, `min_size`, `max_size`.
- [x] `launch_template { id = aws_launch_template.node.id, version = aws_launch_template.node.latest_version }`.
- [x] `taint { key = "workload-class", value = "secure", effect = "NO_SCHEDULE" }` (always).
- [x] Additional taints merged from `var.additional_taints`.
- [x] `labels` set from `local.runtime_labels` (merged
      `workload-class=secure` + `runtime=gvisor` + arch label +
      `var.additional_labels`).
- [x] `update_config { max_unavailable_percentage = ... }`.
- [x] `lifecycle { ignore_changes = [scaling_config[0].desired_size] }`.
- [x] `tags = var.tags`.

#### Success Criteria

- `terraform validate` clean.
- Plan shows `ami_type == "AL2023_ARM_64_STANDARD"` when
  `architecture.name == "arm64"`.
- Plan shows the cluster name + private subnet IDs read from remote
  state.
- Plan shows the `workload-class=secure:NO_SCHEDULE` taint exists.
- Plan shows `runtime=gvisor` and `workload-class=secure` labels.

---

### Phase 6: Outputs and USAGE.md generation

Land the output contract and regenerate the module docs.

#### Tasks

- [x] `outputs.tf`: `nodegroup_name`, `architecture` (echoed),
      `ami_type`, `node_role_arn`, `node_role_name`,
      `instance_profile_arn`, `launch_template_id`,
      `launch_template_latest_version`, `node_labels`, `node_taints`.
- [x] Run `terraform-docs .` to regenerate `USAGE.md`.
- [x] Update `README.md` with: pointer to USAGE.md, `RuntimeClass`
      manifest (kubectl + Argo+Kustomize delivery examples per
      ADR-0011), how to instantiate per arch.

#### Success Criteria

- `terraform-docs .` produces a `USAGE.md` containing every variable
  and output with descriptions.
- `terraform validate` still clean.
- The plan-time output values match the resource attributes they
  reference (e.g., `output.node_role_arn == aws_iam_role.node.arn`).

---

### Phase 7: terraform test plan-only suite (tests/)

Per RFC-0001 and ADR-0013: ship the default `terraform test` plan-only
suite. No LocalStack, no env vars, fast CI gate.

#### Tasks

- [x] `tests/default.tftest.hcl`: default-config plan with
      `override_data` for `data.terraform_remote_state.eks` and `.vpc`.
      Provider config with `skip_credentials_validation = true` so
      no AWS contact. Assertions from DESIGN-0001 §"Static
      validation":
      - IAM role has exactly the worker + ECR-pull-only managed
        attachments (count == 2 when SSM disabled).
      - Launch template `metadata_options[0].http_tokens == "required"`.
      - Launch template `metadata_options[0].http_put_response_hop_limit == 2`.
      - Launch template `block_device_mappings[0].ebs[0].encrypted == true`.
      - Launch template KMS key id from stubbed remote state.
      - Node group has `workload-class=secure:NO_SCHEDULE` taint.
      - Node group `ami_type` matches `architecture.ami_type`.
      - Node group `labels` include `runtime=gvisor` +
        `workload-class=secure`.
      - All 10 outputs declared.
- [x] `tests/architecture_validation.tftest.hcl`: variable validation
      runs.
      - `architecture.name = "x86"` rejected (only `arm64`/`amd64`).
      - `architecture.name = "amd64"` accepted; `ami_type =
        AL2023_x86_64_STANDARD`.
      - `capacity_type = "FOO"` rejected (only `ON_DEMAND`/`SPOT`).
- [x] `tests/ssm_enabled.tftest.hcl`: `enable_ssm = true` adds the
      third managed attachment.
- [x] All runs pass with `terraform test` from the module dir.

#### Success Criteria

- `just tf test eks/managed-node-group` passes in <5s with no
  LocalStack required.
- Every Phase 8 (apply) invariant has a corresponding plan-time
  assertion here.
- Adding a `permissive` IAM attachment to the role in a draft change
  causes the IAM-shape assertion to fail.

---

### Phase 8: terraform test apply-LocalStack suite (tests-localstack/)

Per RFC-0001 §`terraform test` as the gap-discovery tool: exercise
apply against LocalStack Pro to surface what LocalStack does and
doesn't serve for managed node groups.

#### Tasks

- [ ] `tests-localstack/fixtures/setup/main.tf`: VPC + subnets + S3
      bucket + stub `eks` remote state + stub `vpc` remote state.
      The stub `eks` state contains placeholder cluster outputs
      (`cluster_name`, `cluster_endpoint`, `cluster_ca_data`,
      `cluster_oidc_issuer_url`, `cluster_security_group_id`,
      `node_security_group_id`, `kms_key_arn`).
- [ ] `tests-localstack/apply_localstack.tftest.hcl`: AWS provider
      configured with LocalStack endpoints (cluster module's v6-valid
      shape). `command = apply` runs:
      - `setup` — applies the fixture, produces cluster + VPC stub
        state files in LocalStack S3.
      - `default_apply` — applies the managed node group module.
- [ ] Apply-time assertions on returned values:
      - `aws_iam_role.node.arn` populated.
      - `aws_iam_instance_profile.node.arn` populated.
      - `aws_launch_template.node.id` populated.
      - `aws_eks_node_group.this.arn` populated.
      - `aws_eks_node_group.this.status` (whatever LocalStack
        returns — finding documented inline).
- [ ] Document findings inline per RFC-0001's gap-discovery loop:
      - Does LocalStack Pro fully implement `aws_eks_node_group`
        (registration, status transitions)?
      - Does the user_data base64 round-trip work?
      - Does `aws_iam_instance_profile` propagation work as expected?
- [ ] Verify the apply-LocalStack mode runs via
      `just tf test-localstack eks/managed-node-group`.

#### Success Criteria

- `just tf test-localstack eks/managed-node-group` passes against a
  running LocalStack Pro container with the env-var wiring the
  recipe handles.
- Any LocalStack 501 / stub-fidelity gap surfaced is filed inline
  as a sneakystack ticket comment in `apply_localstack.tftest.hcl`.
- If kubelet-join validation is desired but not catchable in
  LocalStack alone (likely the case), a libtftest harness ticket is
  filed referencing RFC-0001 §Phase 3 — but **the module does not
  migrate to libtftest** until the harness covers it (per RFC-0001
  migration trigger).

---

## File Changes

| File                                                              | Action | Description                                                                                  |
| ----------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------- |
| `modules/eks/managed-node-group/versions.tf`                      | Create | terraform >=1.1, aws ~>6.2                                                                   |
| `modules/eks/managed-node-group/variables.tf`                     | Create | Required + typed optional inputs                                                             |
| `modules/eks/managed-node-group/locals.tf`                        | Create | runtime_labels merge                                                                         |
| `modules/eks/managed-node-group/data.tf`                          | Create | terraform_remote_state for eks + vpc                                                         |
| `modules/eks/managed-node-group/iam.tf`                           | Create | Phase 2: node role + 2 managed attachments + optional SSM + instance profile                 |
| `modules/eks/managed-node-group/launch_template.tf`               | Create | Phase 3: launch template with IMDS hardening + KMS-encrypted EBS                             |
| `modules/eks/managed-node-group/user_data.tf`                     | Create | Phase 4: templatefile() invocation                                                           |
| `modules/eks/managed-node-group/templates/user_data.sh.tftpl`     | Create | Phase 4: AL2023 + gVisor install                                                             |
| `modules/eks/managed-node-group/main.tf`                          | Create | Phase 5: aws_eks_node_group                                                                  |
| `modules/eks/managed-node-group/outputs.tf`                       | Create | Phase 6: 10-output contract                                                                  |
| `modules/eks/managed-node-group/README.md`                        | Create | RuntimeClass manifest examples + per-arch instantiation guide                                |
| `modules/eks/managed-node-group/USAGE.md`                         | Regen  | terraform-docs                                                                               |
| `modules/eks/managed-node-group/.terraform-docs.yml`              | Create | Copy from cluster module                                                                     |
| `modules/eks/managed-node-group/.tflint.hcl`                      | Create | Copy from cluster module                                                                     |
| `modules/eks/managed-node-group/tests/`                           | Create | Phase 7: terraform test plan-only suite                                                      |
| `modules/eks/managed-node-group/tests-localstack/`                | Create | Phase 8: terraform test apply-LocalStack suite                                               |

## Testing Plan

- [ ] `terraform validate` clean after each phase.
- [ ] `tflint` clean after each phase.
- [ ] `terraform fmt -check -recursive` clean.
- [ ] `terraform-docs .` produces a non-empty USAGE.md after Phase 6.
- [ ] `just tf test eks/managed-node-group` — every plan-time invariant
      from DESIGN-0001 §Testing Strategy covered.
- [ ] `just tf test-localstack eks/managed-node-group` — apply against
      LocalStack succeeds; any gaps captured inline.
- [ ] Post-deploy integration checks (`kubectl get nodes`, gVisor
      banner, IMDS smoke test) — deferred to the consumer Terragrunt
      stack in infrastructure-live per RFC-0001's out-of-scope clause.

## Dependencies

- **IMPL-0001 merged** — the cluster module's remote-state contract is
  what this module reads from. (Already merged on `main`.)
- **mise toolchain** — Terraform, terraform-docs, tflint, just; AWS
  provider 6.2+; LocalStack Pro 2026.x for Phase 8.
- **No upstream module dependencies via Terraform** — cross-module data
  flows through S3 remote state per ADR-0001.
- **VPC stack** — provides the VPC and subnets referenced via the
  stubbed remote state in tests, and the real remote state at deploy
  time.

## Open Questions

All resolved 2026-05-15.

### Q1 — Module-scaffolding distribution mechanism

**Resolved.** Defer to a separate workstream. Boilerplate templates went
crusty in prior projects; copy-paste-from-cluster-module continues to
work through the four-module fleet. The longer-term shape is a top-level
`tmpl/` directory + a `just tf new <module-path>` recipe that copies the
canonical scaffolding into a new module dir, plus a CI smoke test that
verifies every module under `modules/eks/*` has `.tflint.hcl`,
`.terraform-docs.yml`, `versions.tf`, and `USAGE.md` with the
`<!-- BEGIN_TF_DOCS -->` markers. Tracked as separate work (likely an
INV doc); does not block this implementation. Phase 1 references the
`just tf new` recipe with a copy-paste fallback if it doesn't yet exist.

### Q2 — gVisor SHA-512 verification source

**Resolved A.** Hardcode the digest as a `var.gvisor_sha512` input that
Renovate updates alongside `var.gvisor_version`. Downloading
`runsc.sha512` from the same GCS bucket at install time is
supply-chain self-certification and defeats the purpose of pinning. The
Renovate manager config (handled by infrastructure-live, not this repo)
keeps both fields lockstep on each gVisor release bump.

### Q3 — Kubelet-join LocalStack fidelity in Phase 8

**Resolved A.** Test it at Phase 8 and capture findings — proceed
regardless. If `aws_eks_node_group.status` never reaches `ACTIVE`
because LocalStack fakes registration without the data-plane
handshake, that's the explicit gap-discovery signal per RFC-0001:
captured in `tests-localstack/FINDINGS.md` as sneakystack /
libtftest backlog, and Phase 8 assertions are loosened to whatever
status LocalStack does return.

### Q4 — gVisor systrap on arm64

**Resolved A.** systrap on both architectures per DESIGN-0001 and
ADR-0006. systrap on arm64 is upstream-supported; the conservative
`--platform=ptrace` fallback adds complexity for an unmeasured concern.
Validation that gVisor actually initializes on a real Graviton node
lives in the post-deploy Terragrunt-unit integration tests, **not** in
this IMPL's scope — restated in the README per DESIGN-0001.

### Q5 — Renovate pinning UX

**Resolved A.** Pin a default for `var.gvisor_version` (e.g.,
`"release-20250915.0"` at IMPL-completion time) and Renovate manages
the bump in this repo. Matches the "module is mostly a pure function"
framing — callers override only when they want to. `null` default plus
caller-side mandatory-pinning trades fleet-wide consistency for marginal
explicitness; not worth it.

### Q6 — `var.extra_node_policies` for opt-in ECR pull-through policy

Added during IMPL-0005 review: the managed-node-group module needs a
`var.extra_node_policies = []` input that consumers wire to
`module.ecr_pull_through_cache.node_pull_through_policy_arn` to attach
the opt-in third managed policy per [ADR-0015](../adr/0015-permit-opt-in-third-managed-policy-on-node-role-for-ecr-pull.md).
**Default `[]`** — empty list, no extra attachments unless the
consumer's Terragrunt config explicitly opts in.

Mechanism: in `iam.tf`, add `resource "aws_iam_role_policy_attachment"
"extra"` with `for_each = toset(var.extra_node_policies)`,
`role = aws_iam_role.this.name`, `policy_arn = each.value`. Phase 2
acceptance criteria gain: with `var.extra_node_policies = []` the plan
contains exactly 2 (or 3 with `enable_ssm = true`) managed-policy
attachments; with one ARN passed in, exactly one additional attachment
appears.

### Q7 — Containerd pull-through registry mirror in user data

Added during IMPL-0005 review (Q8 cross-reference). When opted in,
Phase 4's user data writes
`/etc/containerd/config.toml.d/mirror.toml` redirecting configured
upstream registries (Docker Hub, Quay, etc.) to the pull-through cache
URL. **Off by default / opt-in** to match the IAM gate from ADR-0015 —
no scenario where you want the mirror without the IAM, and there are
scenarios where you want the IAM without the mirror (cache-only ECR
public migration; brownfield cluster validating the cache before
redirecting real traffic).

Input shape:
```hcl
variable "containerd_pull_through_mirror" {
  description = "When enabled, user data writes a containerd config dropin redirecting the listed upstream registries to cache_url_prefix. Requires the corresponding ECR pull-through cache module to be instantiated and the matching node IAM policy attached via var.extra_node_policies."
  type = object({
    enabled          = bool
    cache_url_prefix = optional(string)  # e.g. "123456789012.dkr.ecr.us-east-1.amazonaws.com"
    upstreams        = optional(list(object({ host = string, prefix = string })), [])
  })
  default = { enabled = false }
}
```

Plan-time validation: when `enabled = true`, `cache_url_prefix` must be
non-null and `upstreams` non-empty. Failure mode: misconfigured mirror
silently breaks every pod that starts on that node — opt-in default is
the failure-mode-bias-correct choice.

## References

- [DESIGN-0001: Secure EKS Managed Node Group with gVisor](../design/0001-secure-eks-managed-node-group-with-gvisor.md)
- [DESIGN-0002: EKS Cluster Module](../design/0002-eks-cluster-module.md)
- [IMPL-0001: EKS Cluster Module Implementation](0001-eks-cluster-module-implementation.md) — the upstream module whose remote state this consumes.
- [RFC-0001: Module Testing Strategy](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) / [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — testing-framework selection.
- ADRs 0001, 0002, 0005, 0006, 0007, 0008, 0009, 0010, 0011, 0012 — all constraining this module.
