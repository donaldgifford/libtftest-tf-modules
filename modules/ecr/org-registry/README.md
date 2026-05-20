<!-- markdownlint-disable-file MD025 MD041 -->
# Org-Wide ECR OCI Artifact Registry Module

Fleet-shared module that provisions the org-wide OCI artifact registry —
two `aws_ecr_repository_creation_template` resources (one per managed
prefix: `helm-charts/`, `tf-modules/`), a shared module-managed KMS
key, an ECR-assumed IAM role driving template behavior, and a reusable
publisher IAM policy that CI / IRSA roles attach to push internal
Helm charts and Terraform modules.

Implements
[DESIGN-0006](../../../docs/design/0006-org-wide-ecr-oci-artifact-registry.md)
([RFC-0002](../../../docs/rfc/0002-ecr-layout-for-internal-oci-artifacts.md) /
[ADR-0016](../../../docs/adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md)).

Instantiated **once per artifact-hosting account+region**, not per
cluster — the OCI artifact registry is account-scoped fleet
infrastructure.

See [USAGE.md](./USAGE.md) for the generated input / output reference.

## Prerequisites

### AWS Organizations ID

Pass the org ID literal to `var.organizations_org_id` (12-char
`o-...` string). Available in the AWS console under
**Organizations → Settings**, or via:

```bash
aws organizations describe-organization \
  --query 'Organization.Id' --output text
```

The module does **not** read this value via
`data.aws_organizations_organization` — it's a required input. Matches
the fleet's
[ADR-0001](../../../docs/adr/0001-cross-module-composition-via-terraformremotestate.md)
"all cross-stack data is either remote state or explicit input"
posture (IMPL-0006 Q2 (a)).

### Provider pin

`hashicorp/aws ~> 6.2`. The `IMMUTABLE_WITH_EXCLUSION` tag mutability
mode requires `>= 6.8.0`; the currently-installed `v6.45.0` satisfies
this. Terraform `>= 1.1`.

### Greenfield assumption

The two creation templates apply to **future** repos under the
managed prefixes (CREATE_ON_PUSH). Template edits do NOT backfill
existing repos — if pre-existing `helm-charts/*` or `tf-modules/*`
repos exist in the target account, handle migration via a one-shot
operational PR outside this module (no module-emitted migration
tooling per IMPL-0006 Q4).

## Typical instantiation

```hcl
module "org_registry" {
  source = "../../modules/ecr/org-registry"

  name_prefix          = "platform"
  organizations_org_id = "o-abc1234567"

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}
```

For same-account CI discovery via SSM:

```hcl
module "org_registry" {
  source = "../../modules/ecr/org-registry"

  name_prefix          = "platform"
  organizations_org_id = "o-abc1234567"

  publish_to_ssm = true
}
```

For cross-account CI distribution:

```hcl
module "org_registry" {
  source = "../../modules/ecr/org-registry"

  name_prefix              = "platform"
  organizations_org_id     = "o-abc1234567"
  publish_to_ssm           = true
  ssm_cross_account_org_id = "o-abc1234567"
}
```

## Post-apply smoke

```bash
# 1. Log helm into the host account's ECR.
aws ecr get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin \
    <account_id>.dkr.ecr.us-east-1.amazonaws.com

# 2. Push a chart through the create-on-push path.
helm push billing-api-0.5.0-rc1.tgz \
  oci://<account_id>.dkr.ecr.us-east-1.amazonaws.com/helm-charts

# 3. Confirm the repo was auto-created with the template's policy.
aws ecr describe-repositories \
  --repository-names helm-charts/billing-api \
  --region us-east-1
```

`describe-repositories` should return the auto-vivified repo with the
KMS encryption configuration, IMMUTABLE_WITH_EXCLUSION tag mutability
(with `latest` excluded), and the embedded lifecycle policy.

## Consumer integration — attaching the publisher policy

### Same-account CI / IRSA roles

Set `var.publish_to_ssm = true`. Consumer Terraform reads the policy
ARN from the SSM parameter and attaches it via
`aws_iam_role_policy_attachment`:

```hcl
data "aws_ssm_parameter" "publisher_arn" {
  name = "/platform/ecr-oci-publisher-policy-arn"
}

resource "aws_iam_role_policy_attachment" "ci_publisher" {
  role       = aws_iam_role.ci.name
  policy_arn = data.aws_ssm_parameter.publisher_arn.value
}
```

### Cross-account CI / IRSA roles

Set `var.publish_to_ssm = true` AND
`var.ssm_cross_account_org_id = "<your-org-id>"`. The SSM parameters
move to Advanced tier in the artifact-hosting account.

**Manual step — post-apply (provider schema gap).** The AWS provider
v6 has no `aws_ssm_resource_policy` resource (verified at
implementation time per IMPL-0005 Q3 pattern); the module emits the
required resource-based policy JSON as the `ssm_org_read_policy_json`
output for operators to attach via AWS CLI:

```bash
# In the artifact-hosting account, after `terraform apply`.
POLICY_JSON=$(terraform output -raw ssm_org_read_policy_json)
ARN_PATH=$(terraform output -raw publisher_policy_ssm_arn_parameter_name)
JSON_PATH=$(terraform output -raw publisher_policy_ssm_json_parameter_name)

for path in "$ARN_PATH" "$JSON_PATH"; do
  RESOURCE_ARN="arn:aws:ssm:us-east-1:<host-account-id>:parameter${path}"
  aws ssm put-resource-policy \
    --resource-arn "$RESOURCE_ARN" \
    --policy "$POLICY_JSON" \
    --region us-east-1
done
```

Consumer accounts then read the policy JSON from the SSM parameter
and recreate the policy locally (IAM policies don't cross account
boundaries by reference):

```hcl
data "aws_ssm_parameter" "publisher_policy_json" {
  provider = aws.artifact_host  # cross-account provider alias
  name     = "/platform/ecr-oci-publisher-policy-json"
}

resource "aws_iam_policy" "ecr_oci_publisher" {
  name   = "ecr-oci-publisher"
  policy = data.aws_ssm_parameter.publisher_policy_json.value
}

resource "aws_iam_role_policy_attachment" "ci_publisher" {
  role       = aws_iam_role.ci.name
  policy_arn = aws_iam_policy.ecr_oci_publisher.arn
}
```

## Operational gotchas

### Template edits don't backfill existing repos

A repo created via CREATE_ON_PUSH inherits its policy / encryption /
lifecycle from the active template **at the time of creation**. Later
template edits change the policy for repos created **after** the
edit — they do NOT propagate to existing repos. Handle backfill via
a one-shot operational PR outside this module (per IMPL-0006 Q4).

### `ecr:CreateRepository` is the critical permission

Without `ecr:CreateRepository` on a publisher role, the first push
fails with a confusing 403 — the helm/oci client reports a generic
"unauthorized" error rather than indicating the repo doesn't exist
and the role can't create it. The emitted `publisher_policy_arn`
includes this action; attach it (don't hand-craft a narrower
substitute).

### KMS key destruction lifecycle

The module-managed KMS key has `lifecycle.prevent_destroy = true`
(per IMPL-0006 Q8). To retire the registry, follow this two-step
procedure:

1. **Empty + delete every repo under the managed prefixes.** The
   module's templates do NOT track or delete these repos — they
   materialize lazily via CREATE_ON_PUSH and live independently of
   the module's Terraform state:

   ```bash
   for repo in $(aws ecr describe-repositories \
       --query 'repositories[?starts_with(repositoryName, `helm-charts/`) || starts_with(repositoryName, `tf-modules/`)].repositoryName' \
       --output text); do
     aws ecr delete-repository --repository-name "$repo" --force
   done
   ```

2. **Open a deliberate PR removing the `lifecycle` block** on
   `aws_kms_key.ecr_oci`, then run `terraform destroy`. The 30-day
   deletion window starts AFTER apply.

Skipping step 1 leaves OCI artifact repos depending on a key
that's scheduled for deletion — all repos under the managed prefixes
become unreadable on day 30.

## Tests

- **Plan-only:** 8 `.tftest.hcl` files / 15 runs. Run via
  `just tf test ecr/org-registry` (~1.5s, no LocalStack).
- **Apply-against-LocalStack:** opt-in suite with a `plan_smoke`
  active run. The full apply is preserved as commented HCL pending
  LocalStack support for `CreateRepositoryCreationTemplate`
  (inherited 501 from IMPL-0005 Phase 9). Run via
  `just tf test-localstack ecr/org-registry`. Findings captured in
  [`tests-localstack/FINDINGS.md`](./tests-localstack/FINDINGS.md).
