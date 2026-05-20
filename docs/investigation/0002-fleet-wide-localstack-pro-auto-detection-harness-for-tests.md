---
id: INV-0002
title: "Fleet-wide LocalStack Pro Auto-Detection Harness for tests-localstack"
status: Open
author: Donald Gifford
created: 2026-05-19
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0002: Fleet-wide LocalStack Pro Auto-Detection Harness for tests-localstack

**Status:** Open
**Author:** Donald Gifford
**Date:** 2026-05-19

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [Observation 1](#observation-1)
  - [Observation 2](#observation-2)
  - [Observation 3](#observation-3)
  - [Observation 4](#observation-4)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [References](#references)
<!--toc:end-->

## Question

Can `tests-localstack/` suites across every fleet module auto-detect
whether the running LocalStack instance is **Pro** or **Community
(free-tier)** and gracefully skip Pro-only test cases when running
against Community, so a single `just tf test-localstack <module>`
invocation succeeds on either tier?

## Hypothesis

Yes — LocalStack exposes a discoverable runtime endpoint
(`/_localstack/info` and/or `/_localstack/health`) that returns the
edition and feature flags. A small `justfile` helper can probe that
endpoint at `tests-localstack` invocation time, export an env var
(e.g., `LOCALSTACK_EDITION=community|pro`), and individual
`.tftest.hcl` files can key off it (via variables passed at the just
recipe layer) to gate Pro-only `run` blocks.

The harder question is whether `terraform test` itself has a
primitive for "skip this run conditionally." If not, the fallback is
to split tests-localstack into `tests-localstack/community/` (works
on either tier) and `tests-localstack/pro/` (Pro-only) directories,
with the just recipe picking based on detection.

## Context

**Triggered by:** [IMPL-0006 Q3](../impl/0006-org-wide-ecr-oci-artifact-registry-module-implementation.md#q3--pro-tier-auto-detection-in-tests-localstack--directionally-resolved)
— surfaced during the IMPL-0006 first-round review on 2026-05-18. The
user direction was "testing should always check if pro is used, if
not revert to non pro tests."

This investigation is **not blocking IMPL-0006 itself**. That
module's `tests-localstack/` suite is tier-agnostic by construction
(uses `var.organizations_org_id` to side-step the Pro-only
Organizations API; the ECR creation-template APIs 501 on both tiers
anyway). The fleet-wide harness only matters once a module's suite
genuinely depends on a Pro-only API surface.

Cross-references:

- [RFC-0001 §`terraform test` as the gap-discovery tool](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — libtftest for apply-time runtime validation without AWS
- Existing `tests-localstack/` suites: `modules/eks/cluster/`,
  `modules/eks/managed-node-group/`, `modules/eks/addons/`,
  `modules/eks/pod-identity-access/`, `modules/ecr/pull-through-cache/`.
  Currently all five assume LocalStack Pro is running (the local dev
  posture); none probe the edition.

## Approach

1. **Inventory LocalStack's edition-discovery endpoints.**
   - `GET /_localstack/info` — returns JSON including
     `edition` (`"community"` or `"pro"`) and `version` fields.
   - `GET /_localstack/health` — returns service-level status; less
     edition-specific but useful for liveness.
   - Confirm the response shape on both Community and Pro at the
     currently-installed LocalStack release.
2. **Inventory each fleet module's `tests-localstack/` suite for
   Pro-only dependencies.** Map each suite to {tier-agnostic |
   Pro-only | mixed}. For mixed suites, identify which `run` blocks
   need Pro.
3. **Evaluate `terraform test`'s conditional-skip primitives.**
   - `expect_failures` doesn't help (that's for variable validation).
   - `run.condition` doesn't exist in `terraform test` as of TF
     1.14.x (verified post-investigation).
   - The available levers are (a) directory split — `tests-
     localstack/community/` vs `tests-localstack/pro/` — and (b) the
     just recipe selecting which directory to pass via
     `-test-directory=`.
4. **Prototype a `justfile` helper recipe.** Pseudocode:

   ```just
   tf-test-localstack-tier MODULE:
     # Detect tier via /_localstack/info
     EDITION=$(curl -s http://localhost:4566/_localstack/info \
       | jq -r '.edition // "unknown"')
     # Pick directories
     DIRS="tests-localstack"
     if [ "$EDITION" = "community" ]; then
       DIRS="tests-localstack/community"
       echo "ℹ  LocalStack Community detected — Pro-only tests skipped"
     fi
     # Loop over directories, invoke terraform test
     for d in $DIRS; do ... done
   ```

5. **Decide split shape.** Either (a) every module gets a community/
   pro/ subdirectory (cheap to skip pro/ on community detection), or
   (b) keep one tests-localstack/ root and use file-naming convention
   (e.g., `*_pro.tftest.hcl` glob) — but that requires file-glob
   support in the just recipe which adds complexity.
6. **Write up the recommendation.** Update the existing five
   `tests-localstack/` suites to declare their tier explicitly
   (README inside each suite saying "tier: agnostic | pro-only").
   Open follow-up PRs to migrate suites into community/pro
   subdirectories where it actually matters.

## Environment

| Component | Version / Value |
|-----------|----------------|
| LocalStack Pro | 2026.5.0 (currently on dev's macOS) |
| LocalStack Community | (to be tested — pull `localstack/localstack:latest` or specific tag) |
| Terraform | 1.14.7 |
| AWS provider | hashicorp/aws v6.45.0 (fleet pin `~> 6.2`) |
| just | (per `mise.toml`) |

## Findings

(populate during the investigation)

### Observation 1

(TBD — `/_localstack/info` response shape on Pro)

### Observation 2

(TBD — `/_localstack/info` response shape on Community)

### Observation 3

(TBD — `terraform test`'s conditional-skip primitives or lack thereof)

### Observation 4

(TBD — per-module tier inventory across the five existing
`tests-localstack/` suites)

## Conclusion

**Answer:** (TBD — pending investigation)

## Recommendation

(TBD — populate after Findings. Expected outcome: a small justfile
helper + an opt-in directory-split convention; landing PR touches
the recipe and any module's tests-localstack that has genuine
Pro-only dependencies. Most existing fleet modules' suites are
already tier-agnostic and unaffected.)

## References

- [IMPL-0006 Q3](../impl/0006-org-wide-ecr-oci-artifact-registry-module-implementation.md) — triggering question.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module Testing Strategy.
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — libtftest for apply-time runtime validation.
- LocalStack: <https://docs.localstack.cloud/references/internal-endpoints/>
- `terraform test` command docs: <https://developer.hashicorp.com/terraform/cli/commands/test>
