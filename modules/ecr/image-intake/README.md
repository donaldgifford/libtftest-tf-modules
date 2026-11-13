<!-- markdownlint-disable-file MD025 MD041 -->
# ECR Image Intake (quarantine and promoted creation templates)

Push-time **creation templates** for a quarantine-then-promote image
flow
([DESIGN-0031](../../../docs/design/0031-ecr-image-intake-and-kms-signing-key-modules.md)):

- a **quarantine** prefix where a sync job (the *writer*) pushes copies
  of upstream images, which expire after a few days;
- one or more **promoted** prefixes that only the *intake* workflow
  writes to, after it has scanned and signed an image;
- the role ECR assumes to apply the templates, an optional EventBridge
  rule that hands each quarantine push to intake, and identity-policy
  JSON for the writer and intake roles.

It owns nothing registry-level. Cross-account pull access to the
promoted prefixes comes from `ecr/registry`, which takes this module's
`promoted_prefixes` output as its `pull_repository_prefixes`.

## The flow

```text
writer (sync job)  --push-->  quarantine/mirror/<host>/<path>   expires after N days
                                    |
                           EventBridge (PUSH, SUCCESS)
                                    v
intake workflow    --pull, scan, verify, copy by digest, sign-->
                              mirror/<host>/<path>               never expires
                                    |
consumer clusters  <--pull (ecr/registry grant), admission verifies signature
```

Upstream hosts keep their dots in repository names
(`mirror/registry.k8s.io/ingress-nginx/controller`). ECR names are
capped at 256 characters.

## Templates only reach new repositories

A creation template applies when ECR **creates** a repository on push.
A repository that existed before the template keeps whatever policy and
settings it had. Apply this module before the first sync, or move
pre-existing repositories aside.

## What each prefix enforces

| | Quarantine | Promoted |
| --- | --- | --- |
| Tag mutability | `MUTABLE` (intake keys on the digest, so tag moves can't redirect it) | `IMMUTABLE_WITH_EXCLUSION`, excluding `sha256-*` by default |
| Lifecycle | Every image expires `quarantine_retention_days` after push | None |
| Repository policy | `DenyNonPipelineImageAccess`: pull, push and delete denied to everyone except writers, intake and admins | `DenyNonIntakeWrites` (push and delete: intake and admins only); `DenyNonAdminPolicyChanges` (policy, mutability, lifecycle, delete repository: admins only) |
| Encryption | AES256, or `kms_key_arn` | Same |

Reads of promoted prefixes are **not** restricted by the template.
Same-account reads follow IAM, and cross-account reads come from
`ecr/registry`.

**Why `sha256-*` is excluded from immutability.** cosign's legacy
signature storage writes the tag `sha256-<digest>.sig` (and `.att`) and
rewrites it on every additional signature or attestation. In a fully
immutable repository the second `cosign attest` fails.

**Why promoted prefixes never expire anything.** A signature or
attestation can be an untagged artifact. An untagged-expiry rule would
silently strip a promoted image of its signature. Revocation happens at
admission, not by deleting images.

### The service-principal exemption

Every Deny pairs `ArnNotLike aws:PrincipalArn` with `BoolIfExists
aws:PrincipalIsAWSService = false`. `aws:PrincipalArn` is absent for AWS
service principals, and `ArnNotLike` on an absent key evaluates true, so
without the second condition the Deny would also block ECR's own
scanning and replication.

### Principals

`writer_principal_arns`, `intake_principal_arns` and
`admin_principal_arns` are all required, and each must be an exact IAM
role or user ARN: no account roots, wildcards, padding or duplicates.
Writers and intake must be disjoint, since a writer that can also
promote skips the intake gate. Writers must be in the registry's own
account (a precondition): a repository-policy exemption grants nothing
cross-account. Include the deploy role in `admin_principal_arns`.

For a role with an IAM path, pass the path-bearing ARN.
`aws:PrincipalArn` carries the path, and a path-stripped spelling would
not match the exemption.

## Usage

```hcl
module "intake" {
  source = "git::https://github.com/donaldgifford/libtftest-tf-modules.git//modules/ecr/image-intake?ref=<tag>"

  name                  = "example-intake"
  writer_principal_arns = ["arn:aws:iam::111111111111:role/example-sync"]
  intake_principal_arns = ["arn:aws:iam::111111111111:role/example-intake"]
  admin_principal_arns  = ["arn:aws:iam::111111111111:role/example-deploy"]

  # Optional: hand quarantine pushes to a queue. Its queue policy
  # belongs to the queue's own stack.
  intake_event_target = { arn = "arn:aws:sqs:us-east-1:111111111111:example-intake" }
}

module "registry" {
  source = "git::https://github.com/donaldgifford/libtftest-tf-modules.git//modules/ecr/registry?ref=<tag>"

  consumer_accounts        = { "222222222222" = {} }
  pull_repository_prefixes = module.intake.promoted_prefixes
}
```

The module creates **no** writer or intake role. Grant
`writer_policy_json` and `intake_policy_json` through `iam/role` or
`eks/pod-identity-access` `inline_policies`, or any role built
elsewhere. The signing permission comes from the signing key's own key
policy (`kms/signing-key`), not from these documents.

## Sync examples

[`examples/`](examples/) shows one way to drive the flow. These are
**examples, not a supported interface**: CI in this repo does not run
them, and nothing here is a tool to depend on. Every name in them is a
placeholder (`example.com`, `example-…`, account `111111111111`).

| File | What it is |
| --- | --- |
| `manifest.example.yaml` | The source of truth: images pinned by digest, charts pinned by archive sha256. PR review approves it; Renovate bumps it |
| `sync-writer.sh` | The writer: drift check, upstream verify, idempotent copy into quarantine, signature carry-over, chart conversion |
| `github-actions-sync.yaml` | Runs `sync-writer.sh` on merge and nightly, with OIDC to the writer role and upstream credentials from Secrets Manager |
| `promote.sh` | The intake side for one image: scan gate, promote by digest, sign and attest with the KMS key |
| `signing-config.no-tlog.json` | A cosign 3 signing config with no transparency-log services |
| `skopeo-sync.example.yaml` | The batch alternative |

Versions they were written against: crane 0.20.6, cosign 3.1.1,
helm 4.2, mikefarah yq 4 and skopeo 1.25. The action SHAs in the
workflow are pinned, with the tag in a comment. cosign sign, attest and
verify with a no-tlog signing config were smoke-run with cosign 3.1.1
against a local `crane registry serve`. The end-to-end run against ECR
is the sandbox runbook's job (IMPL-0027 Phase 7).

### The writer (`crane` + `cosign`)

For each manifest image, `sync-writer.sh`:

1. **Checks for drift.** `crane digest <source>:<tag>` must equal the
   pinned digest. A mismatch means upstream moved the tag, and a human
   decides what happens next, so the entry fails.
2. **Verifies the upstream signature** with `cosign verify`, when the
   manifest entry has a `verify` block (the publisher signs keyless).
3. **Copies by digest, idempotently.** If quarantine already holds the
   digest under that tag, it skips. Otherwise
   `crane copy <source>@<digest> <quarantine>:<tag>` copies every
   platform of a multi-arch index. The check runs first because
   whether ECR accepts an identical re-push to an immutable repository
   is still a sandbox probe. Checking keeps the job idempotent either
   way. The first push to a new repository creates it from the
   quarantine template.
4. **Carries upstream signatures** with `cosign copy --only=sig,att`,
   so intake can re-verify from quarantine.

One failing entry doesn't stop the others, but the run fails. The
functions run in an `|| ...` context, where bash turns `set -e` off, so
each step that must stop an entry checks its own exit status. Keep that
if you adapt the script.

Credentials: the workflow assumes the writer role through GitHub OIDC.
That role's trust policy is created outside this module (DESIGN-0031
OQ 9a), and it gets `writer_policy_json`. Upstream pull credentials
come from a Secrets Manager secret in the registry account, and each
password is masked in the log before use.

### Intake promotion

`promote.sh` stands in for the intake workflow's last step:

1. **Scan gate.** It waits for scan-on-push to finish, then refuses any
   `CRITICAL` finding. This needs scanning on the quarantine prefix
   (`ecr/registry`'s `scanning` input). A real workflow applies its own
   policy here.
2. **Promote by digest:** `crane copy <quarantine>@<digest>
   <promoted>:<tag>`. The first push creates the repository from the
   promoted template.
3. **Sign and attest** with `cosign sign` / `cosign attest --key
   awskms:///<key ARN>`. Use the key **ARN**: aliases do not resolve
   across accounts. The attestation's predicate type is
   `https://example.com/scan/v1`, a placeholder.

**The transparency-log flag depends on the cosign version.** In cosign
3.x the upload is switched off with a signing config that lists no
transparency-log services (`--signing-config
signing-config.no-tlog.json`). The old `--tlog-upload=false` still
parses there but is deprecated. Verifiers must then skip the log too:
`cosign verify --insecure-ignore-tlog=true`, or the admission
controller's equivalent setting.

**Why the `sha256-*` exclusion matters, observed.** With cosign 3.1.1
against a registry without the OCI referrers API, signing and two
attestations all landed under **one** fallback tag,
`sha256-<digest>`, which cosign rewrote each time. Older cosign writes
`sha256-<digest>.sig` and `.att` and rewrites them the same way. Both
need the tag to stay mutable, which the promoted template's default
exclusion allows. Whether ECR's referrers support makes the exclusion
unnecessary is a sandbox probe (DESIGN-0031 OQ 6).

### `skopeo sync` (batch alternative)

```sh
skopeo sync --src yaml --dest docker --all \
  skopeo-sync.example.yaml \
  "${REGISTRY}/quarantine/mirror/registry.k8s.io"
```

Use it for **bulk catch-up**, such as seeding quarantine with many
images at once. Its limits:

- images only, no charts;
- no cosign signature carry-over: run `cosign verify` and `cosign copy`
  separately for signed images;
- no drift check: the digests in its YAML are written by hand;
- images synced by digest arrive **without a tag**.

For day-to-day syncing, prefer the manifest and `sync-writer.sh`.

### Charts

HTTPS chart repositories are converted to OCI:

```sh
helm pull example-chart --repo https://charts.example.com --version 1.2.3
helm push example-chart-1.2.3.tgz \
  "oci://${REGISTRY}/quarantine/mirror/charts.example.com"
```

`helm push` appends the chart name, so the repository is
`quarantine/mirror/charts.example.com/example-chart`. Chart archives
have no registry digest before they are pushed, so the manifest pins
the archive's sha256 and the script checks it after `helm pull`.

## LocalStack

This module has **no LocalStack apply tier**, Community or Pro
(IMPL-0027 Phase 1, OQ 2a):

- token-free Community 4.4 serves no ECR API at all;
- LocalStack Pro 2026.10.7 was probed and cannot apply the module.

| API / behaviour (Pro 2026.10.7) | Result |
| --- | --- |
| `CreateRepositoryCreationTemplate` | **Not implemented** (unchanged since 2026.6.0) |
| `CreateRepository`, `SetRepositoryPolicy`, `IMMUTABLE_WITH_EXCLUSION` | Served |
| ECR push → EventBridge rule → SQS | **No event delivered** |
| A deny-all repository policy | **Not enforced** |

The creation templates are always created and are not implemented, push
events never fire, and repository policies are not enforced. The plan
suite is the gate; the `tests-sandbox/` runbook proves enforcement
against real AWS.

## Tagging

There is no `tags` input (DESIGN-0029). The template role and the event
rule receive provider `default_tags` as usual. Repositories are created
later by ECR, outside the provider, so the templates pass the same set
as `resource_tags`, read back through `data "aws_default_tags"`.

## Tests

| Suite | Tier | What it proves |
| --- | --- | --- |
| `tests/` | plan (the gate), 52 runs | Every default pinned by a bare call; both templates' policies and the quarantine lifecycle decoded; two promoted prefixes rendering independent templates; the template role's trust and scope; the event pattern exact; writer and intake policies granting nothing outside their prefixes; 38 rejections, each verified by isolated message probe to fire its own rule |

Full variable and output reference: [USAGE.md](USAGE.md).
