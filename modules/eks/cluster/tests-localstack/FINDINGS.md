# LocalStack apply findings — `cluster` module

Per [RFC-0001](../../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
§*`terraform test` as the gap-discovery tool*: the `tests-localstack/`
apply suite exists to surface what LocalStack Pro does and doesn't
serve for this module's AWS API surface. Each finding here either
documents a workaround in HCL or files a sneakystack / libtftest
backlog item.

## Environment captured at last run

- LocalStack Pro **2026.6.0** on `:4566`
- Date: 2026-07-01 (first documented run for this module)

> [!NOTE]
> **Pending re-run (IMPL-0020 Phase 5, authored 2026-08-30).** The
> endpoint-fence assertions added to `default_apply`, and the new
> `fenced_apply`, `prefix_list_expands_against_a_real_list`, and
> `rejects_a_real_prefix_list_that_expands_to_nothing` runs, have **not
> been executed live** — no Pro container was available to the authoring
> session. Run `just tf test-localstack eks/cluster` and record the
> result (and the Pro version) here. The offline plan gate for the
> fence — including the zero-diff default pin — is green at 13 runs and
> is unaffected either way.
>
> **The open parity question these runs answer.** The fence has two
> input paths and only one of them was covered live: `fenced_apply`
> passes literal CIDRs, which never touch
> `data.aws_ec2_managed_prefix_list`. The two plan-only runs added
> alongside it exercise the expansion against **real** EC2 prefix lists
> created by the fixture — one populated, one deliberately empty. They
> are the first live answer to whether this emulator serves managed
> prefix lists with their `entries` populated at all. If
> `prefix_list_expands_against_a_real_list` fails on the
> `192.0.2.0/24` assertion, the emulator returned the list without
> entries: record that as a coverage gap and keep the plan suite (which
> stubs the data source) as the gate for the expansion logic. The empty
> list is the live shape of the fence-expands-to-nothing hazard the
> security review surfaced — it must fail the plan, never fall through
> to `0.0.0.0/0`.

## Test runs

| Run | Command | Coverage |
|-----|---------|----------|
| `setup` | apply | Fixture: VPC + private subnets + two managed prefix lists (one populated, one empty) + S3 stub state the cluster reads via remote state |
| `default_apply` | apply | Real `aws_eks_cluster` + IAM cluster role/attachments + module KMS key/alias (secrets envelope encryption) + node security group with ingress/egress rules + CloudWatch log group + EKS access entries |
| `fenced_apply` | apply | The literal-CIDR fence reaching the EKS API as `public_access_cidrs`, replacing the world-open default |
| `prefix_list_expands_against_a_real_list` | plan | `data.aws_ec2_managed_prefix_list` against a real populated list; union de-duplication across both input paths |
| `rejects_a_real_prefix_list_that_expands_to_nothing` | plan | The fence-expands-to-nothing precondition against a real empty list |

Run with `just tf test-localstack eks/cluster`.

## Findings

### Finding #1 — No coverage gaps in the AWS API surface this module touches (as of LocalStack Pro 2026.6.0)

`default_apply` succeeds end-to-end (**2 passed**, with `setup`) against
LocalStack Pro for every resource this module emits —
`aws_eks_cluster`, `aws_iam_role` + `aws_iam_role_policy_attachment`,
`aws_kms_key` + `aws_kms_alias`, `aws_security_group` +
`aws_vpc_security_group_{ingress,egress}_rule`,
`aws_cloudwatch_log_group`, `aws_eks_access_entry` +
`aws_eks_access_policy_association`.

LocalStack Pro populates the computed cluster attributes the suite
asserts on: `endpoint`, `certificate_authority[0].data`,
`identity[0].oidc[0].issuer`, and `vpc_config[0].cluster_security_group_id`.
No 501/NotImplemented surfaced. The AWS-side surface is fully covered by
LocalStack Pro plan + apply at this resolution.

### Out-of-scope of LocalStack apply (libtftest backlog, RFC-0001 §Phase 3)

- A **real Kubernetes control plane** — LocalStack registers the EKS
  cluster and serves its describe attributes but does not run an actual
  API server. `kubectl`-level behavior (RBAC from access entries, the
  OIDC provider actually issuing tokens, workloads scheduling) is not
  exercised. Validating that requires a real cluster or a libtftest
  runtime probe.

## When to re-run

- LocalStack Pro release bumps — re-run to confirm continued coverage and
  refresh the "as of LocalStack Pro X" line above.
- Any change to the module's resource set or the computed attributes the
  suite asserts on.

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
