# LocalStack apply findings — `addons` module

Per [RFC-0001](../../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
§*`terraform test` as the gap-discovery tool*: the `tests-localstack/`
apply suite exists to surface what LocalStack Pro does and doesn't
serve for this module's AWS API surface. Each finding here either
documents a workaround in HCL or files a sneakystack / libtftest
backlog item.

## Environment captured at last run

- LocalStack Pro 2026.5.0.dev121 on `:4566`
- Date: 2026-05-15

## Findings

### Finding #1 — `aws_eks_addon` registration succeeds for every
addon in this module, including the addon-managed
`pod_identity_association` block

The apply suite (`apply_localstack.tftest.hcl::default_apply`) succeeds
end-to-end against LocalStack Pro for every resource this module
creates:

- `aws_eks_addon.pod_identity_agent` — registers, returns a populated
  ARN. No PIA block, no IAM role (matches the agent's special
  position per ADR-0003).
- `aws_eks_addon.vpc_cni` + `aws_eks_addon.ebs_csi_driver` — both
  register, return populated ARNs, and accept the
  `pod_identity_association { service_account, role_arn }` block
  with the expected service_account values readable on the resource
  attribute after apply. This was the headline open question
  (IMPL-0003 §Open Questions): the addon-managed PIA pattern (ADR-0004)
  is supported by LocalStack Pro's EKS API at this resolution.
- `aws_eks_addon.kube_proxy` + `aws_eks_addon.coredns` — both
  register; no IAM, no PIA (matches DESIGN-0003).
- `aws_iam_role.vpc_cni` + `aws_iam_role.ebs_csi` — return populated
  ARNs; managed-policy attachments
  (`AmazonEKS_CNI_Policy`, `AmazonEBSCSIDriverPolicy`) accepted.

No 501 / NotImplemented errors hit at this resolution. The module's
AWS-side surface is fully covered by LocalStack Pro plan + apply.

### Finding #2 — `describe-addon-versions` catalog is populated but
the supported version set is narrower than production AWS

LocalStack Pro publishes a curated subset of addon versions through
`describe-addon-versions`. As of LocalStack Pro 2026.5.0 for K8s 1.35:

- `eks-pod-identity-agent` defaults to `v1.3.10-eksbuild.2`.
- `vpc-cni` defaults to `v1.21.1-eksbuild.7`.
- `kube-proxy` defaults to `v1.35.3-eksbuild.2`.
- `coredns` defaults to `v1.13.2-eksbuild.4`.
- `aws-ebs-csi-driver` defaults to `v1.57.1-eksbuild.1`.
- `aws-efs-csi-driver` defaults to `v2.3.1-eksbuild.1`.

Pinning an arbitrary upstream production version (e.g.
`v1.3.0-eksbuild.1`) returns `InvalidParameterException: Addon
version specified is not supported`. This is a LocalStack catalog
fidelity gap — the apply test works around it by pinning the literal
versions LocalStack publishes (see the `variables` block in
`apply_localstack.tftest.hcl::default_apply`). Plan-only tests under
`tests/` are unaffected because they stub
`data.aws_eks_addon_version` via `override_data`.

**Filed as sneakystack backlog**: parameterize LocalStack's
addon-versions catalog so it can be aligned with production
real-time, or document an "addon-version sync" recipe for
test-fixture pinning.

### Out-of-scope of LocalStack apply (libtftest backlog, RFC-0001 §Phase 3)

These are real apply-time invariants the AWS-side test cannot
exercise without a Kubernetes control plane behind a kind/k3d
bridge:

- **Addon DaemonSet readiness.** `aws_eks_addon` returning success
  on apply means the AWS-side resource is `CREATING`. The actual
  DaemonSet rollout on cluster nodes is not validated by LocalStack
  Pro (no real kubelet, no real EKS control plane scheduling).
- **Pod Identity Association credential delivery.** LocalStack
  registers the PIA block on the addon, but the actual
  `pods.eks.amazonaws.com → role_arn` credential exchange that
  the agent serves to pods is not exercised.
- **CoreDNS configuration_values semantics.** The free-form JSON
  passthrough validates as a string at plan/apply against
  LocalStack — but whether the values are accepted by the real
  CoreDNS Helm chart only surfaces against a real EKS control
  plane.

## Workarounds in HCL (terraform test ergonomics)

These mirror the cluster + managed-node-group modules' findings:

- **`override_data` evaluates statically.** Cross-run dynamic
  stubbing of `data.terraform_remote_state.*` is not expressible.
  Workaround: the fixture module writes a real `terraform.tfstate`
  JSON to a real LocalStack S3 bucket and the module's data source
  resolves naturally.
- **`data.terraform_remote_state` s3 backend ignores the provider's
  `endpoints` block.** Workaround: `AWS_ENDPOINT_URL` env var set
  by the `just tf test-localstack` recipe.

## When to re-run

- LocalStack Pro release bumps — re-run to refresh the supported
  addon-version set in Finding #2 above.
- Module surface changes — any new addon or resource type re-opens
  the gap-discovery question.
- New AWS API features the module starts consuming — same.
