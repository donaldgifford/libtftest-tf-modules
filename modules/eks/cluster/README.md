# cluster

[Usage docs](./USAGE.md)

## Testing

This module is the deliberate side-by-side reference for the
two-framework testing strategy per
[RFC-0001](../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md).
It carries both `terraform test` (plan-time invariants in HCL) and
libtftest (runtime, Go) suites until cluster grows its first
apply-time runtime invariant, at which point the `tests/` suite
retires per RFC-0001's retirement criterion. No other module carries
both frameworks.

### `terraform test` suite — two modes, two directories

**Default mode: plan-only** (`tests/*.tftest.hcl`). No LocalStack, no
env vars, no setup. The fast CI gate.

```bash
cd modules/eks/cluster
terraform init -backend=false
terraform test
```

Runtime: ~1.2s. 4 run blocks (default plan, KMS external, SSO
disabled, SSO enabled). Uses `override_data` to stub
`data.terraform_remote_state.vpc` and `data.aws_caller_identity.current`.

**Opt-in mode: apply-against-LocalStack** (`tests-localstack/*.tftest.hcl`).
The gap-discovery mode per RFC-0001 — `command = apply` against
LocalStack Pro to exercise IAM, KMS, CloudWatch Logs, EKS, EC2 SGs.
Setup fixture creates a real VPC + subnets + S3 bucket + stub
`terraform.tfstate` so the cluster's `data.terraform_remote_state.vpc`
resolves naturally.

Requires (a) a running LocalStack Pro container on `:4566`, and
(b) env vars in the parent shell — the s3 backend of
`data.terraform_remote_state` uses its own AWS SDK independent of
the provider's `endpoints` block, so `AWS_ENDPOINT_URL` is mandatory
even though the provider has explicit endpoints:

```bash
cd modules/eks/cluster
terraform init -backend=false -test-directory=tests-localstack
AWS_ENDPOINT_URL=http://localhost:4566 \
AWS_ACCESS_KEY_ID=test \
AWS_SECRET_ACCESS_KEY=test \
AWS_REGION=us-east-1 \
  terraform test -test-directory=tests-localstack
```

Runtime: ~75s.

### libtftest suite — `test/*_test.go`

Same plan-time invariants today, against a real LocalStack-backed
plan. Requires a running LocalStack Pro container (Community 4.4/3.8
returns 403 InvalidClientTokenId on AWS provider v6.x STS signing).

```bash
cd modules/eks/cluster/test
LIBTFTEST_CONTAINER_URL=http://localhost:4566 go test -tags=integration -v ./...
```

Runtime: ~45 seconds against a warm LocalStack Pro.

Apply-time invariants land here once the libtftest harness covers
them (kind/k3d bridge, sneakystack lifecycle). See
[ADR-0014](../../../docs/adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md).
