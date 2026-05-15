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

### `terraform test` suite — `tests/*.tftest.hcl`

Two modes. Both default-on with a single `terraform test` invocation.

**Plan-only files** (`default.tftest.hcl`, `kms_external.tftest.hcl`,
`sso.tftest.hcl`) — `command = plan` with `override_data` stubs for
`data.terraform_remote_state.vpc` and `data.aws_caller_identity.current`.
No LocalStack required. ~1.2s total. The fast CI gate.

```bash
cd modules/eks/cluster
terraform init -backend=false
terraform test -filter=tests/default.tftest.hcl \
               -filter=tests/kms_external.tftest.hcl \
               -filter=tests/sso.tftest.hcl
```

**Apply-against-LocalStack file** (`apply_localstack.tftest.hcl`) —
`command = apply` against LocalStack Pro. Exercises IAM, KMS,
CloudWatch Logs, EKS, EC2 SGs. The gap-discovery mode per RFC-0001:
every LocalStack 501 / coverage gap surfaces here as a concrete apply
failure → sneakystack ticket.

Requires a running LocalStack Pro container on `:4566`. Also requires
env vars in the parent shell (the s3 backend of
`data.terraform_remote_state.vpc` uses its own AWS SDK independent of
the provider's `endpoints` block):

```bash
cd modules/eks/cluster
terraform init -backend=false
AWS_ENDPOINT_URL=http://localhost:4566 \
AWS_ACCESS_KEY_ID=test \
AWS_SECRET_ACCESS_KEY=test \
AWS_REGION=us-east-1 \
  terraform test
```

Runtime: ~80s (the apply-against-LocalStack run dominates).

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
