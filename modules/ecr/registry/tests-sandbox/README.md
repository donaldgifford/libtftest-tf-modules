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

Run it from a checkout of the merged release tag: the generated stacks
source the module by absolute path from this checkout, so the code
under test is whatever is checked out.

`results.txt` is written to the **current directory** and truncated at
the start of each run. Run each sandbox from its own directory, or
copy the file away before the next run.

The script stops at the first `FAIL`. Its `EXIT` trap then tears down,
so a failed run leaves nothing behind.

### Options

| Variable | Default | Effect |
| --- | --- | --- |
| `REGISTRY_PROFILE` | required | AWS CLI profile for the registry account |
| `CONSUMER_PROFILE` | required | AWS CLI profile for the consumer account |
| `REGION` | `us-east-1` | Region for both accounts |
| `KEEP` | `0` | `1` skips the teardown (see P3 below) |
| `SANDBOX_FORCE` | `0` | `1` runs even if the registry already has a policy. Sandbox only: the run overwrites it |
| `SETTLE_SECONDS` | `15` | Wait after each registry apply before pulling. Raise it if a leg fails on what looks like propagation |

### Restoring the registry account

The first two `RECORD` lines are the scope and scanning configuration
**before** the run. If the destroy leg's `RECORD` lines show something
different, put them back:

```sh
aws ecr put-account-setting --name REGISTRY_POLICY_SCOPE --value <initial>
aws ecr put-registry-scanning-configuration --cli-input-json '<initial JSON>'
```

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

1. Run the script with `KEEP=1`. The scripted legs, including the
   destroy leg, still run. `KEEP=1` only skips the final teardown, so
   the canary repositories, the consumer stack and the generated stack
   directory survive. The last line of `results.txt` names that
   directory (`KEEP=1: leaving <dir> ...`).
2. **Re-apply the registry stack**, which the destroy leg removed.
   Without it the node has no grant, and the pull fails for the wrong
   reason:

   ```sh
   # the stack's provider block already names the registry profile
   terraform -chdir=<dir>/registry apply
   terraform -chdir=<dir>/registry output -raw consumer_identity_policy_json
   ```

3. In the consumer account, pick a node (EKS or plain EC2 with
   containerd) built outside this repo. Attach that JSON to its
   instance role as an inline policy. Change nothing else on the node.
4. Pull by digest. The digest is the `canary` tag in
   `mirror/sbx/canary` (`aws ecr describe-images`). On an EKS node:
   `crictl pull <registry-host>/mirror/sbx/canary@<digest>`, or run a
   pod with that image.
5. Record the result in FINDINGS.md.
6. Clean up by hand. **This is required before the `ecr/image-intake`
   runbook**, whose preflight refuses a registry that has a policy or
   repositories under `mirror/` or `quarantine/`:

   ```sh
   # remove the inline policy from the node's role first
   aws ecr delete-repository --repository-name mirror/sbx/canary --force
   aws ecr delete-repository --repository-name quarantine/sbx/canary --force
   terraform -chdir=<dir>/registry destroy
   terraform -chdir=<dir>/consumer destroy -var identity_policy_json='{}'
   rm -rf <dir>
   ```

   Run the `aws` commands with the registry profile
   (`--profile <REGISTRY_PROFILE>`). The `terraform` commands need no
   setup: each generated stack's provider block already names its
   profile.

kubelet's ECR credential provider fetches the token with the node
role, so no node configuration should be needed. That is what this leg
checks.
