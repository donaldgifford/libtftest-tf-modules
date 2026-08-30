# LocalStack apply findings — `access-entries` module

Per [RFC-0001](../../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
§*`terraform test` as the gap-discovery tool*: the `tests-localstack/`
apply suite exists to surface what LocalStack does and doesn't serve
for this module's AWS API surface. Each finding here either documents
a workaround in HCL or files a sneakystack / libtftest backlog item.

## Environment

- Suite authored 2026-08-30 (IMPL-0020 Phase 5). **Not yet run live** —
  see Finding #1: it needs a LocalStack **Pro** container, whose auth
  token is operator-held.

## Findings

### Finding #1 — EKS is Pro-only; this suite cannot run on the Community tier

Probed directly on 2026-08-30 against the token-free Community image
`localstack/localstack:4.4` (`SERVICES=eks,iam,sts,ec2`):

- the health endpoint reports **no `eks` key at all** (the service is
  not merely `disabled`, it is absent from the Community build);
- `aws --endpoint-url http://localhost:4566 eks list-clusters` returns

  ```text
  An error occurred (InternalFailure) when calling the ListClusters
  operation: The API for service 'eks' is either not included in your
  current license plan or has not yet been emulated by LocalStack.
  ```

This resolves **IMPL-0020 OQ 4** empirically. The APIs are wholly
absent from Community, so the fallback the OQ anticipated (a
Community-safe `plan_smoke`) would prove nothing that the plan suite
does not already prove offline. Instead this suite carries the **same
Pro requirement its three sibling eks consumers already carry**
(`addons`, `managed-node-group`, `pod-identity-access` all record Pro
in their own FINDINGS), and it stays in `tests-localstack/` rather than
`tests-localstack-pro/` — the latter is reserved for surfaces that must
*not* run under the default `test-localstack` recipe (RDS Proxy,
IMPL-0010 Q7), which is not the case here.

**Consequence for the plan gate:** unchanged. `tests/` (12 runs) is and
remains this module's gate; it needs no LocalStack at all.

### Finding #2 — What this suite is designed to prove that the plan suite cannot

Recorded here so the value of running it is explicit when a Pro
container is available:

1. **`aws_eks_access_entry` / `aws_eks_access_policy_association`
   coverage** — whether LocalStack Pro populates `access_entry_arn`,
   accepts both `cluster` and `namespace` access scopes, and honours
   the flattened one-association-per-pair shape.
2. **The collision guard against a real remote-state read.** The plan
   suite stubs `data.terraform_remote_state.eks` with `override_data`;
   here the guard reads an actual S3 state object seeded by the
   fixture, so the `try()` lookup is exercised against real state
   decoding rather than a synthetic map.
3. **The stale-state degrade path, live.** The fixture seeds a *second*
   state object with no `sso_principal_arn` output (IMPL-0020 OQ 3a —
   the reason the bespoke fixture was chosen over composing the real
   cluster module). A pre-DESIGN-0024 cluster state must degrade to
   no-guard, and that is asserted against a real read.

### Pending — run and record

When a Pro container is available:

```sh
just tf test-localstack eks/access-entries
```

Then replace the Environment section above with the captured Pro
version and record, per the fleet's assert-what-round-trips discipline,
any API surface that does not round-trip.
