# cluster

[Usage docs](./USAGE.md)

## API endpoint access

`endpoint_private_access` (default `true`) and `endpoint_public_access`
(default `true`) select the endpoint posture; the hub keeps both, spokes run
private-only (`endpoint_public_access = false`). Two additive inputs fence the
public endpoint:

| Input                                    | Effect                                                  |
| ---------------------------------------- | ------------------------------------------------------- |
| `endpoint_public_access_cidrs`           | literal CIDRs added to the fence                        |
| `endpoint_public_access_prefix_list_ids` | managed prefix lists, expanded to CIDRs **at plan time** |

The effective fence is the **de-duplicated union** of both. An empty union
resolves to `["0.0.0.0/0"]` — exactly the value EKS already applies implicitly,
so a cluster that sets neither input replans with **zero diff**.

Three guards fail at plan rather than at apply: at least one endpoint must be
enabled; fence inputs set while the public endpoint is off are rejected (a
fence on a disabled endpoint is a misconfiguration, not a silent no-op); and
the union must stay within the EKS limit of 40 CIDRs.

> [!WARNING]
> **Prefix-list expansion is plan-time only.** Unlike a security-group rule's
> `prefix_list_id` — which is a *live* reference that tracks the list — the EKS
> API accepts literal CIDRs, so this module snapshots each list's entries when
> it plans. **Edits to a prefix list do not reach the cluster until this
> stack's next apply.** If you need live tracking of a source list, that is a
> security-group rule's job (`modules/network/security-group`, DESIGN-0026), not
> this fence's.
>
> The expansion also counts against the 40-CIDR public-endpoint limit — a
> corporate egress list can consume it faster than expected. The plan guard
> names both inputs when it trips.
>
> Live sync is a recorded follow-up (an out-of-band syncer plus a module-wide
> ignored-fence posture decision), not a v1 knob: a conditional
> `ignore_changes` cannot exist, because Terraform `lifecycle` arguments are
> static and cannot reference variables (INV-0011 OQ 12).

## Cluster creator admin permissions

`access_config.bootstrap_cluster_creator_admin_permissions` is set explicitly
to `true`. This is the value that already applied silently as the provider
default — writing it changes nothing, but it makes the posture reviewable and
attaches this contract to it:

> [!IMPORTANT]
> The bootstrap admin entry binds to **whatever principal creates the
> cluster**, permanently. Cluster applies must therefore run through the
> **stable automation path** — Atlantis under its pod-identity role, assuming
> the per-account deploy role — and **not** an ad-hoc operator SSO session. An
> `AWSReservedSSO_*` creator is a rotating principal: permission-set changes
> re-mint the role suffix, and the bootstrap entry silently goes stale, leaving
> a cluster whose day-0 admin no longer resolves.

If a day-0 bring-up does happen from an SSO workstation, treat the resulting
bootstrap entry as **disposable**: it is superseded by the declared
`eks/access-entries` map (DESIGN-0024 part 1) and can be deleted out-of-band
once that stack is green. Moving to `false` plus an explicit deploy-role entry
is the recorded follow-up posture once the hub pattern burns in — it is
feasible per-cluster at create time, and the flag forces replacement after.

Until the entries stack applies, this bootstrap entry is the access floor: a
wrong or absent entries stack can never lock the fleet out of a fresh cluster.

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

## Remote-state key contract (ADR-0020)

This module **reads** the VPC facts at:

```text
<account_name>/<region>/vpc/<vpc_name>/terraform.tfstate
```

and its own state **must be published at** (i.e. the Terragrunt live-repo
directory must be):

```text
<account_name>/<region>/eks/<cluster_name>/terraform.tfstate
```

`cluster_name` is both the live-repo folder name and the key every EKS
consumer (`managed-node-group`, `addons`, `pod-identity-access`,
`efs/filesystem`) composes to find this cluster's state. A mismatch fails
the consumer plan with `Unable to find remote state` (the error names
neither bucket nor key — diff against this contract). The key template is
pinned by a plan assertion in `tests/default.tftest.hcl`; see ADR-0020 for
the fleet table.
