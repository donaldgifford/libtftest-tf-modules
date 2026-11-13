<!-- markdownlint-disable-file MD025 MD041 -->
# Sandbox runbook: ecr/registry

Real-AWS proof of what neither LocalStack tier can show (see the
module README's "LocalStack" section): that the registry policy is
**enforced** across accounts. Operator-run, never CI (IMPL-0027 Phase
7, DESIGN-0030 OQ 11a). Results go in [FINDINGS.md](FINDINGS.md).

## Use a dedicated sandbox account

The run overwrites three **per-registry singletons** in the registry
account: the registry policy, `REGISTRY_POLICY_SCOPE` and the scanning
configuration. It refuses to start if a registry policy already exists
(override with `SANDBOX_FORCE=1` only in a sandbox). It records the
initial scope and scanning configuration first, so you can restore
them.

## Prerequisites

- Two AWS CLI profiles: `REGISTRY_PROFILE` (registry account) and
  `CONSUMER_PROFILE` (a second account). The consumer principal must
  be able to create IAM roles and assume them.
- terraform >= 1.9, aws cli v2, crane, jq.

## Run

```sh
REGISTRY_PROFILE=sbx-registry CONSUMER_PROFILE=sbx-consumer \
REGION=us-east-1 ./run.sh
```

`results.txt` collects every line. `KEEP=1` leaves the stacks in place
for inspection; destroy them by hand afterwards.

## Legs

| Leg | What the script does | Expectation |
| --- | --- | --- |
| P1 ordering | Sets the scope to `V1`, then one `terraform apply` | The apply sets `V2` and writes the policy without error (the `depends_on`) |
| P1 | A consumer role pulls `mirror/sbx/canary` by digest; the repository has no repository policy | Allowed |
| P2 | The same role pulls `quarantine/sbx/canary` | Refused |
| P2 over-broad | Adds a pass-through statement granting the consumer pull on `repository/*` | Quarantine still refused (`ConsumerDenyProtected`); mirror still allowed |
| Narrowing | `principal_arn_patterns = [".../role/sbx-node-*"]` | `sbx-node-a` allowed, `sbx-other` refused |
| P1 V1 probe | Deletes the policy, sets `V1`, writes the pull policy by CLI, pulls | **Recorded**: does a V1 registry reject the grant at `PutRegistryPolicy` (as LocalStack Pro does), or accept it and refuse the pull? |
| Destroy | `terraform destroy`, then pulls | Refused; scope and scanning afterwards **recorded** |

Pulls use `crane export`, which fetches the manifest and the layer, so
both `BatchGetImage` and `GetDownloadUrlForLayer` are exercised.

## P3: a node this repo did not build (manual)

DESIGN-0030 assumes consumer clusters may be built without this repo's
modules. Prove that a node needs nothing beyond the identity policy:

1. Run the script with `KEEP=1`, so the registry stack and the canary
   stay up.
2. In the consumer account, pick a node (EKS or plain EC2 with
   containerd) built outside this repo. Attach the stack's
   `consumer_identity_policy_json` output to its instance role as an
   inline policy. Change nothing else on the node.
3. Pull by digest. On an EKS node:
   `crictl pull <registry-host>/mirror/sbx/canary@<digest>`, or run a
   pod with that image.
4. Record the result in FINDINGS.md, then remove the inline policy and
   destroy the stacks.

kubelet's ECR credential provider fetches the token with the node
role, so no node configuration should be needed. That is what this leg
checks.
