# LocalStack apply findings — `managed-node-group` module

Per [RFC-0001](../../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
§*`terraform test` as the gap-discovery tool*: the `tests-localstack/`
apply suite exists to surface what LocalStack Pro does and doesn't
serve for this module's AWS API surface. Each finding here either
documents a workaround in HCL or files a sneakystack / libtftest
backlog item.

## Environment captured at last run

- LocalStack Pro **2026.6.0** on `:4566` — re-verified 2026-07-01
  (`setup` + `default_apply`, **2 passed**), coverage unchanged
- First captured on Pro 2026.5.0.dev121 (2026-05-15)

> [!NOTE]
> **Pending re-run (IMPL-0020 Phase 5, authored 2026-08-30).** The
> workload-class assertions added to `default_apply` (now asserting the
> **core** default: class label, no class taint) and the new
> `secure_class_apply` and `mirror_without_gvisor_apply` runs have **not
> been executed live** — no Pro container was available to the authoring
> session. Run `just tf test-localstack eks/managed-node-group` and
> record the result here. Note the behavior change this suite now
> encodes: the default apply is a **core** group, not the
> pre-DESIGN-0024 secure one. The offline plan gate is green at 24 runs,
> including the fleet's first rendered-user-data assertions.
>
> **What `mirror_without_gvisor_apply` is for.** The ECR pull-through
> mirror config renders into the *same* shellscript MIME part as the
> gVisor install, so gating that whole part on gVisor — which is how
> DESIGN-0024 literally reads — would silently drop the mirror on every
> non-gVisor class. That failure is invisible: nodes boot fine and just
> pull from upstream. The plan suite pins the rendered text; this run is
> the only place EC2 is asked to *accept* the resulting multipart user
> data with the mirror on and gVisor off. If it fails at
> `CreateLaunchTemplate` rather than on an assertion, the finding is
> about the emulator's multipart handling, not the module.

## Findings

### Finding #1 — No coverage gaps in the AWS API surface this module touches (as of LocalStack Pro 2026.5.0)

The apply suite (`apply_localstack.tftest.hcl::default_apply`) succeeds
end-to-end against LocalStack Pro for every resource this module
creates:

- `aws_iam_role.node` + `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly` attachments.
- `aws_iam_instance_profile.node`.
- `aws_launch_template.node` with IMDSv2 + hop=2 + KMS-encrypted EBS
  (`kms_key_id` resolved from the cluster module's stubbed state).
- `aws_eks_node_group.this` registers, returns a populated ARN, and
  accepts both `AL2023_ARM_64_STANDARD` ami_type and `ON_DEMAND`
  capacity_type.

No 501 / NotImplemented errors hit at this resolution. The module's
AWS-side surface is fully covered by LocalStack Pro plan + apply.

### Out-of-scope of LocalStack apply (libtftest backlog, RFC-0001 §Phase 3)

These are real apply-time invariants the AWS-side test cannot exercise
without a Kubernetes control plane behind a kind/k3d bridge:

- **Kubelet-join validation.** LocalStack EKS fakes node-group
  registration but does not run a real control plane. The
  `aws_eks_node_group.status` transition to `ACTIVE` is not
  meaningfully tested here. Filed as candidate libtftest scope:
  the harness needs sneakystack + kind/k3d for the data plane.
- **gVisor `runsc` initialization.** The launch template's user data
  installs runsc; LocalStack does not provision EC2 instances. Real
  Graviton + AL2023 boot is post-deploy integration on a real cluster.
- **Pod Identity Agent reachability via IMDS hop=2.** Same constraint —
  no real kubelet, no real IMDS host.

### Workarounds in HCL (terraform test ergonomics)

These are documented inline in `apply_localstack.tftest.hcl` and
mirror the cluster module's findings:

- **`override_data` evaluates statically.** Cross-run dynamic stubbing
  of `data.terraform_remote_state.*` is not expressible. Workaround:
  the fixture module writes real `terraform.tfstate` JSON to a real
  LocalStack S3 bucket and the module's data source resolves
  naturally.
- **`data.terraform_remote_state` s3 backend ignores the provider's
  `endpoints` block.** Workaround: `AWS_ENDPOINT_URL` env var set by
  the `just tf test-localstack` recipe.

## When to re-run

- LocalStack Pro release bumps — re-run to confirm continued coverage,
  refresh the "as of LocalStack Pro X" line above.
- Module surface changes — any new resource type appearing in this
  module re-opens the gap-discovery question.
- New AWS API features the module starts consuming — same.

## IMPL-0015 — Terragrunt account-scoped remote-state read

This module's `data.terraform_remote_state` read(s) were migrated to the
Terragrunt multi-account shape (IMPL-0015): the account-scoped key
`<account_name>/<region>/<shape>/terraform.tfstate`, `region =
<remote_state_bucket_region>`, and a cross-account `assume_role`
(`role_arn = arn:aws:iam::<account_id>:role/<deploy_role_name>`,
`session_name = "Deploy-Tf"`).

LocalStack finding (Phase 1 spike, re-confirmed by this apply suite): the global
`AWS_ENDPOINT_URL` (wired by the `just tf test*` recipes) routes **both** the STS
`AssumeRole` call and the S3 GET to LocalStack — no `endpoints {}` block is
needed inside the backend `config`. LocalStack STS mints temporary credentials
for **any** role ARN (it does not verify the role exists), so the setup fixture
need not pre-create the IAM role. The six Terragrunt-provided globals
(`account_name`/`account_id`/`region`/`remote_state_bucket`/
`remote_state_bucket_region`/`deploy_role_name`) come from the shared
`test/fixtures/terragrunt-inputs.tfvars`, passed via `-var-file` by the recipes;
the setup run seeds its stub state at the matching account-scoped key.

## DESIGN-0029 / IMPL-0026 — provider `default_tags` (2026-11-11)

> [!NOTE]
> **Pending re-run (IMPL-0026 3.5, authored 2026-11-11).** The module no
> longer declares a `tags` input. This suite's provider block now sets
> `default_tags` (`ManagedBy`, `Suite`) instead. The apply has **not been
> executed live** with that change: this suite's baseline is LocalStack
> Pro, and IMPL-0026 deliberately adds no Pro dependency (OQ 3/4). Without
> a fresh before-state on the same tier, a failure could not be told apart
> from an emulator gap. Run `just tf test-localstack eks/managed-node-group` on Pro and
> record the result here. The offline plan gate, including
> `tests/default_tags.tftest.hcl`, is green either way.
> The one site here that `default_tags` cannot reach on its own, the
> launch template's `tag_specifications`, is proven live on Community
> 4.4 instead, by IMPL-0026 Phase 4 probe B (an EC2-only replica).

## IMPL-0026 Phase 4 probe B — launch-template upgrade diff (2026-11-11)

**Status: the vehicle failed; resolved at the source (see Resolution below).** IMPL-0026 4.3
planned an EC2-only replica of this module's launch template on
token-free 4.4, because EKS is Pro-only. The replica copied the tag
sites verbatim from `v0.26.0` (variant 1) and from the working tree
(variant 2). It ran on `localstack/localstack:4.4` (Community 4.4.0)
with Terraform 1.15.8 and hashicorp/aws 6.72.0.

### Community 4.4 cannot observe launch-template tagging

Three emulator gaps, each confirmed in the raw
`DescribeLaunchTemplateVersions` / `DescribeLaunchTemplates` output:

1. **`LaunchTemplateData.TagSpecifications` is stored as `[{}, {}]`.**
   Both `ResourceType` and `Tags` are dropped. Variant 1 replans with a
   new version immediately after its own apply, with no config change.
2. **Create-time template tags leak into version 1's data.** A template
   created with resource `tags` reads back a phantom
   `tag_specifications { resource_type = "launch-template" }`. Real EC2
   keeps those separate.
3. **Tags added by update are never read back.** A template created
   untagged, then tagged, reads back `tags = {}`.

Any tagged launch template on 4.4 therefore drifts against its own
config, and every "no new version" check reads as a version bump. That
also applies to this suite's eventual live runs on a Pro image if Pro
shares the gaps (unverified).

### What is established without the live run

- **Rendered `tag_specifications` are byte-identical.** IMPL-0026 2.2's
  plan-tier run pins both blocks against the literal `v0.26.0`
  rendering, mutation-checked. A differential plan on 4.4 agrees. From
  one shared applied state, variant 1 with `default_tags = X` (the
  status quo) and variant 2 with `default_tags = X` (the migration)
  plan **identical** launch-template data in every field except
  resource `tags`. The control, variant 2 with one default value
  changed, differs in `tag_specifications` only.
- **Apply creates no version for a tags-only change.**
  `resourceLaunchTemplateUpdate` (aws provider v6.72.0) calls
  `CreateLaunchTemplateVersion` only when `d.HasChanges(updateKeys...)`.
  `updateKeys` includes `tag_specifications` but not `tags` or
  `tags_all`, which go through the generated tagging interceptor.
- **But the plan shows `latest_version` as known after apply.** The
  resource's CustomizeDiff runs `customdiff.ComputedIf("latest_version",
  ...)` (and the same for `default_version` when
  `update_default_version = true`) for **any** changed key except
  `name`, `name_prefix`, `description`, `default_version`,
  `update_default_version`. The migration changes the template's own
  `tags` (X → none), so the upgrade plan for this module will show
  `aws_eks_node_group.this` with `~ launch_template.version = "N" ->
  (known after apply)`. From the source, it should resolve to the same
  N at apply, and the node group's update should no-op. **That is
  inferred, not observed.**

### Resolution (operator decision, 2026-11-11)

The module now removes the hazard at the source.
`aws_launch_template.node` sets `tags = data.aws_default_tags.this.tags`,
so the template's own `tags` reproduce `v0.26.0`'s `var.tags` exactly
when the stack's `default_tags` equal its old `tags` input (DESIGN-0029
rollout step 3). With no `tags` change, CustomizeDiff leaves
`latest_version` known and the node group plans no diff.
`tests/default.tftest.hcl` pins the template's `tags` to the literal
`v0.26.0` rendering. The same literal passes on the `v0.26.0` worktree,
and removing the line reds the assert.

