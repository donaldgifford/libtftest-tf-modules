<!-- markdownlint-disable-file MD025 MD041 -->
# Org-Wide ECR OCI Artifact Registry Module

Fleet-shared module that provisions the org-wide OCI artifact registry —
two `aws_ecr_repository_creation_template` resources (one per managed
prefix: `helm-charts/`, `tf-modules/`), a shared module-managed KMS key,
an ECR-assumed IAM role driving template behavior, and a reusable
publisher IAM policy that CI / IRSA roles attach to push internal Helm
charts and Terraform modules.

Implements
[DESIGN-0006](../../../docs/design/0006-org-wide-ecr-oci-artifact-registry.md)
([RFC-0002](../../../docs/rfc/0002-ecr-layout-for-internal-oci-artifacts.md) /
[ADR-0016](../../../docs/adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md)).

Instantiated **once per artifact-hosting account+region**, not per
cluster — the OCI artifact registry is account-scoped fleet
infrastructure.

See [USAGE.md](./USAGE.md) for the generated input / output reference.
