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
