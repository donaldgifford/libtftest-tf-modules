<!-- markdownlint-disable-file MD025 MD041 -->
# Sandbox runbook: ecr/image-intake

Real-AWS proof of what LocalStack cannot show: creation templates,
repository-policy enforcement, push events and cosign against real
ECR. Operator-run, never CI (IMPL-0027 Phase 7). Results go in
[FINDINGS.md](FINDINGS.md).

The run applies this module together with `ecr/registry` and
`kms/signing-key`, because the legs need all three. The intake
workflow is stood in for by a plain `sbx-intake` role driven from the
script (IMPL-0027 OQ 5a).

## Use a dedicated sandbox account

The registry account gets a registry policy, a scanning configuration
and creation templates for `quarantine`, `mirror` and `strict`.
`preflight` refuses to start if the registry already has a policy, any
creation template, or repositories under those prefixes. Templates only
reach **new** repositories, so pre-existing ones would make the legs
lie.

Teardown deletes every repository under the three prefixes, then
destroys the stacks. The signing key enters its 30-day deletion window
and the encryption leg's key its 7-day window, so expect a small KMS
charge until they go.

## Prerequisites

- `REGISTRY_PROFILE` and `CONSUMER_PROFILE`: two accounts. Both
  principals must be able to create IAM roles and assume them.
- `OPERATOR_ARN`: the IAM role ARN behind `REGISTRY_PROFILE`, **with
  its path** (`aws iam get-role --role-name <name>`). It becomes the
  admin of the templates and of the signing key. `aws:PrincipalArn`
  carries the path, so a path-stripped spelling would not be exempt
  from the Denys, and the teardown could not delete the promoted
  repositories.
- terraform >= 1.9, aws cli v2, crane, cosign 3.x, jq, mikefarah yq 4.
- Network access to `public.ecr.aws` (the upstream image, override
  with `UPSTREAM`).

## Run

```sh
REGISTRY_PROFILE=sbx-registry CONSUMER_PROFILE=sbx-consumer \
OPERATOR_ARN=arn:aws:iam::<registry-account>:role/<path>/<name> \
REGION=us-east-1 ./run.sh
```

`results.txt` collects every line. `KEEP=1` skips the teardown.

## Legs

| Leg | What the script does | Expectation |
| --- | --- | --- |
| Writer | `sbx-writer` copies the upstream image into `quarantine/…`, then tries `mirror/…` | Quarantine OK (create-on-push); mirror denied. The mirror denial is IAM: the writer policy has no grant there |
| Services | Waits for scan-on-push on the quarantine image | Completes: the `BoolIfExists` exemption lets ECR's scanner through the Deny |
| Lifecycle | Reads the quarantine repository's lifecycle policy | Attached. Expiry itself is not awaited |
| Events | Reads the intake queue after the quarantine push, and again after the mirror push | At least one event for quarantine; none for mirror |
| Intake | `sbx-intake` pulls from quarantine and copies to `mirror/…` by digest | Both OK |
| Isolation | `sbx-unrelated` (identity policy `ecr:*` on `*`) pulls quarantine and pushes mirror; the consumer pulls both | Unrelated refused twice (only the repository policies stop it); consumer refused on quarantine, allowed on mirror |
| cosign | `sign` and `attest` on the mirror digest with the KMS key | OK under the default `sha256-*` exclusion; the resulting tags are **recorded** |
| cosign, strict | The same on `strict/…`, whose exclusion matches nothing cosign writes, in the default mode and with `--registry-referrers-mode=oci-1-1` | **Recorded**: does ECR's referrers support make `sha256-*` unnecessary (DESIGN-0031 OQ 6)? |
| Re-push | `crane tag` re-PUTs the same tag and digest to the immutable mirror repository (`crane copy` would skip it) | **Recorded** |
| Examples | `examples/sync-writer.sh` as the writer, `examples/promote.sh` as intake | Both succeed end to end |
| Encryption | Re-applies with a CMK under its **default** key policy, pushes and promotes into new repositories, and pulls from the consumer account | **Recorded** (INV-0012 P4); the README's KMS guidance is written from it |
