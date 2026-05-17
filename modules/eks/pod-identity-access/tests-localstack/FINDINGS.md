# LocalStack apply findings — `pod-identity-access` module

Per [RFC-0001](../../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
§*`terraform test` as the gap-discovery tool*: the `tests-localstack/`
apply suite exists to surface what LocalStack Pro does and doesn't
serve for this module's AWS API surface. Each finding here either
documents a workaround in HCL or files a sneakystack / libtftest
backlog item.

## Environment captured at last run

- LocalStack Pro 2026.5.0.dev121 on `:4566`
- Date: 2026-05-17

## Findings

### Finding #1 — IMPL-0004 Q3 resolved: `aws_eks_pod_identity_association`
is fully supported by LocalStack Pro at this resolution

The apply suite (`apply_localstack.tftest.hcl::apply_mode_a` +
`::apply_mode_b`) succeeds end-to-end against LocalStack Pro for
every resource this module creates:

- **Mode A apply** — the module creates `aws_iam_role.this[0]` with
  the Pod Identity trust policy, attaches the requested managed
  policy, attaches the requested inline policy, and registers
  `aws_eks_pod_identity_association.this` against the cluster. All
  ARNs / IDs return populated; the association's `role_arn` matches
  the created role.
- **Mode B apply** — caller passes the pre-existing role ARN from
  the setup fixture as `var.existing_role_arn`. Zero IAM roles are
  created by the module; the association registers and the
  association's `role_arn` matches the pre-existing role.
- `aws_iam_role` + `aws_iam_role_policy_attachment` (managed flavor)
  + `aws_iam_role_policy` (inline flavor) — all populated ARNs.

No 501 / NotImplemented errors hit at this resolution. The brand-new
EKS Pod Identity Association API is covered by LocalStack Pro plan +
apply. This was the headline open question — answered.

### Out-of-scope of LocalStack apply (libtftest backlog, RFC-0001 §Phase 3)

Per IMPL-0004 Q4: these are real apply-time invariants the AWS-side
test cannot exercise without a Kubernetes control plane behind a
kind/k3d bridge, regardless of LocalStack fidelity:

- **Pod Identity Agent credential delivery.** LocalStack registers
  the association but does not run a real Pod Identity Agent. The
  pods.eks.amazonaws.com → role_arn → STS credentials chain that
  the agent serves to pods is not exercised. Validating "association
  exists → agent vends credentials → workload SDK consumes them"
  needs a real K8s data plane fronted by sneakystack.
- **Association eventual consistency.** AWS's published propagation
  window for the association reaching agents on every node doesn't
  manifest in LocalStack (no real kubelet, no real agent on
  scheduled pods). The credential-propagation retry/backoff is the
  thing libtftest needs to exercise against a real EKS cluster
  fronted by sneakystack — captured as a libtftest backlog item.
- **ServiceAccount linkage.** This module does NOT create the
  Kubernetes ServiceAccount it binds to (ADR-0011 — AWS API only).
  Out-of-band Argo/Helm delivers the SA; validating that the
  association resolves against an actual ServiceAccount needs a
  real K8s cluster.

## Workarounds in HCL (terraform test ergonomics)

These mirror the cluster + managed-node-group + addons modules'
findings:

- **`override_data` evaluates statically.** Cross-run dynamic
  stubbing of `data.terraform_remote_state.*` is not expressible.
  Workaround: the fixture module writes a real `terraform.tfstate`
  JSON to a real LocalStack S3 bucket and the module's data source
  resolves naturally.
- **`data.terraform_remote_state` s3 backend ignores the provider's
  `endpoints` block.** Workaround: `AWS_ENDPOINT_URL` env var set
  by the `just tf test-localstack` recipe.

## When to re-run

- LocalStack Pro release bumps — re-run to confirm continued
  coverage of `aws_eks_pod_identity_association`.
- Module surface changes — any new resource type appearing in this
  module re-opens the gap-discovery question.
- AWS announces backwards-incompatible changes to the Pod Identity
  Association API — same.
