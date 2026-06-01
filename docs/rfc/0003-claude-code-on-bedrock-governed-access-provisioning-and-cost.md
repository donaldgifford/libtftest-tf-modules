---
id: RFC-0003
title: "Claude Code on Bedrock governed access provisioning and cost tracking"
status: Draft
author: Donald Gifford
created: 2026-05-31
---
<!-- markdownlint-disable-file MD025 MD041 -->

# RFC 0003: Claude Code on Bedrock governed access provisioning and cost tracking

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-31

<!--toc:start-->
- [Summary](#summary)
- [Problem Statement](#problem-statement)
- [Proposed Solution](#proposed-solution)
- [Design](#design)
- [Alternatives Considered](#alternatives-considered)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Foundations (provisioning plane)](#phase-1-foundations-provisioning-plane)
  - [Phase 2: Cost visibility and alerting](#phase-2-cost-visibility-and-alerting)
  - [Phase 3: Credential lifecycle and (optional) federation](#phase-3-credential-lifecycle-and-optional-federation)
- [Risks and Mitigations](#risks-and-mitigations)
- [Success Criteria](#success-criteria)
- [References](#references)
<!--toc:end-->

## Summary

Stand up Claude Code on Amazon Bedrock in an account that currently has nothing
enabled, with a credential that is least-privilege, rotatable, and kept out of
Terraform state. Attribute the spend of that credential precisely and fire
threshold alerts before it runs away. The credential is minted and rotated by a
small Go tool; everything declarative (IAM, inference profiles, budgets,
notifications) is Terraform; per-credential cost attribution rides on
application inference profile (AIP) cost-allocation tags, with IAM-principal
allocation as a complementary lens.

## Problem Statement

We want developers to run Claude Code through Bedrock (data stays in our AWS
boundary, unified billing, IAM governance) rather than the direct Anthropic API.
The target account has no Bedrock usage, no inference profiles, no budgets, and
no credential plumbing today.

Two hard requirements drive the design:

1. **Per-credential cost attribution.** We need to know what _this_ token costs,
   not just the account's aggregate Bedrock bill. On-demand model invocations
   cannot be tagged directly — tagging the model, agent, or IAM resource does
   not propagate to billing line items. Attribution requires a deliberate
   mechanism (AIPs and/or IAM-principal allocation).
2. **Threshold alerting.** Notify at configurable dollar thresholds (and on
   anomalous spikes) with enough lead time to act, accepting that billing-based
   signals are not real-time.

Secondary constraints: long-term Bedrock API keys are long-lived bearer tokens
(AWS positions them as exploration-only) and have a track record of leaking; the
default `AmazonBedrockLimitedAccess` managed policy is broader than its name
implies. The design must contain blast radius and avoid persisting the secret in
Terraform state.

## Proposed Solution

**Account placement (preferred first move).** If we can carve a dedicated
account from the landing zone for Claude Code, account-level cost is trivially
tracked with a single account-scoped budget and the per-AIP tag work below
becomes optional refinement rather than load-bearing. Anthropic's own Bedrock
guidance recommends a dedicated account precisely to simplify cost tracking and
access control. This RFC assumes we may _not_ get a dedicated account and
therefore designs full per-credential attribution that works in a shared
account.

**Credential.** A long-term Bedrock API key, which underlyingly is an IAM user
plus an IAM service-specific credential for `bedrock.amazonaws.com`. We replace
the default managed policy with a tight customer-managed policy scoped to only
our AIP ARNs plus `bedrock:GetInferenceProfile`. Expiry is set (e.g. 90 days)
and rotation uses the two-key-per-user allowance for zero-downtime rollover. A
Bedrock bearer token is meaningfully safer for Claude Code than full AWS
credentials because it cannot be reused by spawned subprocesses for non-Bedrock
operations.

**Secret handling.** The Go tool mints the key
(`CreateServiceSpecificCredential`) and writes the one-time-visible value
straight into Vault (preferred, aligns with our JIT-secrets pattern) or AWS
Secrets Manager. The secret never touches Terraform state.

**Cost attribution.** One AIP per model we expose (primary + small/fast at
minimum), each carrying a consistent cost-allocation tag set. Claude Code's
`ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL` point at the AIP ARNs; Claude
Code resolves the AIP to its backing model via `bedrock:GetInferenceProfile`.
Tags flow into Cost Explorer and CUR 2.0 (~24h latency, not retroactive). As a
second lens — and the cleanest 1:1 with "this token" — we tag the backing IAM
user and use Bedrock's IAM-principal cost allocation (GA April 2026).

**Alerting.** AWS Budgets filtered on the cost-allocation tag, notifying at
50/80/100% actual and 100% forecasted via SNS to email and Slack. Cost Anomaly
Detection provides spike protection. For faster-than-billing signal, alarm on
Bedrock CloudWatch token-count metrics per profile (volume now, dollars later).

## Design

See **[DESIGN-0009](../design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md)**
for the concrete Terraform module contract, Go tool CLI surface, and
prerequisite enablement procedure. High-level component map:

```text
 developer ─ Claude Code (env: CLAUDE_CODE_USE_BEDROCK, AWS_REGION,
                 ANTHROPIC_MODEL=<AIP ARN>, AWS_BEARER_TOKEN_BEDROCK)
                 │  bearer token (from Vault / Secrets Manager)
                 ▼
            Bedrock runtime ── invokes via AIP ARN ──► foundation model
                 │                                        │
                 │ tagged usage                           │ token metrics
                 ▼                                        ▼
        CUR 2.0 + Cost Explorer (tag + IAM principal)   CloudWatch
                 │                                        │
                 ▼                                        ▼
            AWS Budgets ──► SNS ──► email / Slack    CloudWatch alarm (early signal)
                 ▲
        Cost Anomaly Detection (spike guard)

 provisioning plane:
   Terraform  ──► IAM user + scoped policy, AIPs (tagged), budgets, SNS,
                  (CUR export), cost-allocation tag activation*
   Go tool    ──► mint/rotate key → Vault/SM, submit Anthropic use-case form
                  (PutUseCaseForModelAccess) at org management account
   (*tag activation: local in this account when standalone/management, else the payer component)
```

## Alternatives Considered

- **CDK instead of Terraform.** No advantage here and off our paved road
  (Terragrunt/Terraform). Rejected.
- **OIDC/SSO federation (e.g. the AWS
  "guidance-for-claude-code-with-amazon-bedrock" Cognito pattern) instead of a
  long-term key.** Stronger for broad team rollout with full per-user
  attribution and no long-lived secret. Heavier to stand up. **This is not a
  separate rejected alternative — it is the deferred-to-Phase-3 version of
  this same alternative.** Phase 1 + 2 ship the long-term key because the
  initial goal in §Problem Statement is single-credential; once team-wide
  Claude Code adoption arrives, Phase 3 migrates to federation and retires the
  long-term key. The Phase 3 entry in §Implementation Phases is the migration,
  not a re-evaluation.
- **Raw IAM access keys for Claude Code.** Worse blast radius (usable for any
  AWS operation by subprocesses) and no Bedrock-scoping benefit. Rejected.
- **IAM-principal cost allocation as the _only_ mechanism.** Maps 1:1 to the
  token and needs no AIPs, but is newer and gives no per-model breakdown, and
  doesn't let Claude Code enforce profile usage. Kept as a complementary lens,
  not the primary.
- **Per-team account-per-credential.** Cleanest attribution of all (account =
  cost boundary); folded into the "dedicated account" preferred move rather
  than treated as a separate option.

## Implementation Phases

### Phase 1: Foundations (provisioning plane)

- Go tool: `enable-models` submits the Anthropic use-case form at the org
  management account so it cascades to members.
- Terraform: IAM user + scoped customer-managed policy, AIPs (tagged) for
  primary + small/fast models, SNS topic + subscriptions.
- Activate the cost-allocation tag — locally via
  `cost_allocation_tag_activation = "local"` if this is a standalone/management
  account, otherwise via the payer component.

### Phase 2: Cost visibility and alerting

- Terraform: tag-filtered AWS Budgets with notification thresholds; optional
  CUR 2.0 data export with caller-identity (IAM principal) allocation.
- CloudWatch alarm on per-AIP token-count metrics for early signal.
- Validate tags appear in Cost Explorer (allow ~24h) and a forced threshold
  fires an alert.

### Phase 3: Credential lifecycle and (optional) federation

- Go tool: `rotate` / `revoke` against the two-key allowance; scheduled
  rotation.
- Migrate team-wide usage to OIDC/SSO federation (the deferred half of the
  alternative evaluated in §Alternatives Considered), retiring the long-term
  key. Trigger: a concrete signal that the single-credential model is no
  longer fit — multiple teams sharing the credential, per-developer
  attribution becomes a hard requirement, or the long-term key's blast radius
  outweighs its operational simplicity. Until then, Phase 3 is on the
  backlog, not on the critical path.

## Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Long-term key leaks (public repo, logs) | High | Medium | Store only in Vault/SM; never in TF state or `.env` committed files; short expiry + rotation; scoped policy limits damage to Bedrock-on-our-AIPs |
| `AmazonBedrockLimitedAccess` over-broad | Medium | High (default) | Do not attach it; use a custom policy scoped to AIP ARNs + `GetInferenceProfile` |
| Secret captured in Terraform state | High | High (if minted in TF) | Mint outside Terraform in the Go tool; write directly to Vault/SM |
| Billing signal lag means no hard cap | Medium | High | Budgets are guardrails not caps; add CloudWatch token-metric alarm for early signal; anomaly detection for spikes |
| Cost-allocation tags not retroactive / 24h delay | Low | High | Activate tags before first invoke; document the lag; baseline expectations |
| AIP version sprawl (one profile per model version) | Low | Medium | Module parameterizes models; treat new model versions as new AIPs via the same module |
| Tag activation requires payer-level scope | Medium | High | Module `cost_allocation_tag_activation` flag: `local` for standalone/management accounts, `payer` component for org member accounts; member-account resources stay separate |
| Marketplace permission missing at first invoke | Low | Medium | Enablement principal holds `aws-marketplace:Subscribe` once; or run `enable-models` from a principal that has it |

## Success Criteria

- A developer can run `claude` against Bedrock using only the bearer token from
  Vault/SM, with no other AWS credentials configured.
- Cost Explorer shows Bedrock spend filtered to the credential's tag (and/or
  IAM principal) within ~24h of first use.
- A deliberately low test budget threshold produces an email and Slack alert.
- The key can be rotated with no interruption to an active session window.
- No secret value appears anywhere in Terraform state or plan output.

## References

- [DESIGN-0009](../design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md) — Claude Code on Bedrock: module, tool, and enablement contracts
- AWS: simplified Bedrock model access / retirement of the Model Access page and `PutFoundationModelEntitlement` (Sep–Oct 2025)
- AWS: Bedrock cost allocation by IAM principal (Apr 2026)
- AWS: application inference profiles and cost-allocation tags
- Anthropic: Claude Code on Amazon Bedrock (settings, dedicated-account guidance)
