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

Plan-time invariants only. No AWS contact, no LocalStack required —
`override_data` blocks stub `data.terraform_remote_state.vpc` and
`data.aws_caller_identity.current`. Fast and cheap.

```bash
cd modules/eks/cluster
terraform init -backend=false
terraform test
```

Runtime: ~1–2 seconds.

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
