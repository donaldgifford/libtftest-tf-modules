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
