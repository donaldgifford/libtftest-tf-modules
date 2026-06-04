<!-- markdownlint-disable-file MD025 MD041 -->
# `bedrock-keyctl`

The companion CLI to
[`modules/bedrock/claude-code`](../../modules/bedrock/claude-code/README.md).
It owns the two things Terraform deliberately does not: the IAM
service-specific credential (the `AWS_BEARER_TOKEN_BEDROCK` bearer token
Claude Code consumes — a one-time secret that must never touch Terraform
state) and per-provider Bedrock model-access enablement.

The secret is **never printed or logged** — it is written only to a secret
sink. This is enforced structurally by an opaque `credential.SecretValue`
type whose `String`/`GoString`/`MarshalJSON` all redact; the raw value is
reachable only through `Reveal`, confined by an unexported witness token to
the sink boundary.

Implements
[IMPL-0009](../../docs/impl/0009-claude-code-on-bedrock-module-go-tool-implementation.md)
Part II / [DESIGN-0009](../../docs/design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md)
§2–3.

## Build & install

Go 1.26.4 (pinned in `mise.toml`; run `mise install` first). After any Go
bump, `mise install go@<pin>` so the active binary matches the `go.mod`
directive — otherwise `go-licenses` fails on the toolchain-module stdlib.

```bash
cd tools/bedrock-keyctl
go build ./...            # build
go install ./...          # install bedrock-keyctl onto $GOBIN
go test ./...             # unit tests (~88% coverage)
golangci-lint run ./...   # lint (Uber set)
govulncheck ./...         # vuln scan
```

Global flags (all subcommands): `--region`, `--log-level
debug|info|warn|error`, `--dry-run` (print intended actions without
calling AWS mutating APIs).

## Subcommands

### `mint`

Create a new credential and write the secret envelope to the sink. Prints
the credential ID and expiry only.

```bash
bedrock-keyctl mint \
  --user platform-ai-claude-code \
  --sink sm://bedrock/claude-code/platform-ai \
  --expiry-days 90
```

### `rotate`

Two-key zero-downtime handoff: mint a new credential, verify it, write it
to the sink, then retire the old one (deactivate → grace period → delete).
If verification fails, the new key is rolled back and the old one is left
Active, so the sink always holds a working secret.

```bash
bedrock-keyctl rotate \
  --user platform-ai-claude-code \
  --sink sm://bedrock/claude-code/platform-ai \
  --verify-profile <inference-profile-id> \
  --grace-period 5m
```

`--verify-profile` probes the new token against an AIP via
`GetInferenceProfile` before retiring the old key; omit it to skip
verification (not recommended). `--grace-period 0` deletes the old key
immediately. The grace sleep is interruptible (SIGINT/SIGTERM).

### `revoke`

Targeted deactivate → delete (→ optional sink purge). IAM-before-sink so a
revoked key can never linger valid for an in-flight request. Run this
before `terraform destroy`.

```bash
bedrock-keyctl revoke \
  --user platform-ai-claude-code \
  --credential-id <id> \
  --sink sm://bedrock/claude-code/platform-ai \
  --force            # skip the confirmation prompt (CI / non-interactive)
```

Omit `--sink` for a 2-step IAM-only revoke.

### `enable-models`

Dispatch per-provider model-access enablement. `--models` is a
comma-separated `<provider>.<model_id>` list or `@file.json` (a JSON array
of `{provider, model_id}` objects).

```bash
# Single account (default)
bedrock-keyctl enable-models \
  --models anthropic.claude-3-5-sonnet-20241022-v2,amazon.nova-pro-v1,meta.llama3-1-70b-instruct-v1 \
  --target-accounts current

# Anthropic org cascade (management account)
bedrock-keyctl enable-models --models anthropic.claude-3-opus-20240229-v1 \
  --target-accounts org-management

# Fleet enablement across member accounts
bedrock-keyctl enable-models --models meta.llama3-1-70b-instruct-v1 \
  --target-accounts 111122223333,444455556666 \
  --assume-role-name bedrock-enablement
```

Provider routing (DESIGN-0009 §3): Path A (`anthropic`) submits the
one-time use-case form (idempotent); Path B (`amazon`) is a no-op; Path C
(`meta`/`mistral`/`cohere`/`ai21`/`stability`/`openai`) tries an explicit
Marketplace subscribe then falls back to a no-op invocation trigger
(`--marketplace-subscribe-path auto|explicit|invocation`, default `auto`).
Results print as a per-account `MODEL | PROVIDER | ACTION | OUTCOME` table.

**Cross-account caveat:** Anthropic enablement cascades to member accounts
from `org-management`; other providers do not (a warning row directs you to
`--target-accounts=<account-id-list>`).

## Cross-account setup

For `--target-accounts=<account-id-list>`, each target account needs a
role (default `bedrock-enablement`) trusting the tooling-account principal:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<tooling-account-id>:role/<tooling-role>" },
    "Action": "sts:AssumeRole"
  }]
}
```

Permissions on that role are the enablement-principal permissions for the
provider mix dispatched in that account (see the module README's IAM
contract): Anthropic → `bedrock:PutUseCaseForModelAccess`; third-party →
`aws-marketplace:Subscribe`, `aws-marketplace:ViewSubscriptions`,
`bedrock:InvokeModel`. The tooling principal needs `sts:AssumeRole` to each
target role.

## Sink configuration

v1 supports AWS Secrets Manager only (Vault deferred to v1.1 per
DESIGN-0009 Q7):

```text
sm://<secret-name>
```

The payload is a JSON envelope (DESIGN-0009 Q5):

```json
{
  "bedrock_api_key": "<the bearer token>",
  "credential_id": "<IAM service-specific credential ID>",
  "expires_at": "2026-09-01T12:00:00Z"
}
```

The developer's environment reads `bedrock_api_key` into
`AWS_BEARER_TOKEN_BEDROCK` at session start. `mint`/`rotate` write the full
envelope; `revoke --sink` deletes it.

## Manual sandbox verification (Q14)

End-to-end cost-attribution verification is a **manual operator recipe**,
deliberately not a CI job (DESIGN-0009 Q14 — LocalStack Community can't do
Bedrock or `CreateServiceSpecificCredential`; see the module's
`tests-localstack/FINDINGS.md`):

1. Apply `modules/bedrock/claude-code` into a sandbox account with a
   distinctive `cost_tag` (e.g. `{ key = "Team", value = "sandbox-verify" }`).
2. Enable access:
   `bedrock-keyctl enable-models --models anthropic.claude-3-5-haiku-20241022-v1 --target-accounts current`.
3. Mint a short-expiry key:
   `bedrock-keyctl mint --user <iam_user_name> --sink sm://sandbox-verify --expiry-days 1`.
4. Export the token from the sink and invoke once through an AIP:
   `AWS_BEARER_TOKEN_BEDROCK=<token> aws bedrock-runtime invoke-model --model-id <aip_arn> ...`.
5. Wait ~24h, then confirm the `Team=sandbox-verify` dimension surfaces in
   Cost Explorer (the ~24h lag is why the CloudWatch token alarm exists).
6. Clean up:
   `bedrock-keyctl revoke --user <iam_user_name> --credential-id <id> --sink sm://sandbox-verify --force`,
   then `terraform destroy`.

## Architecture

| Package | Responsibility |
|---------|----------------|
| `cmd/` | cobra command tree (root + mint/rotate/revoke/enable-models) |
| `internal/awsapi` | narrow, mockable IAM / Bedrock / Marketplace / STS clients (domain types, not SDK structs); SDK-error → domain-sentinel translation |
| `internal/credential` | opaque `SecretValue` (redacting; `Reveal(SinkToken)`) — structural enforcement of the secret-never-logged invariant |
| `internal/sink` | `Sink` interface + Secrets Manager implementation + the JSON envelope codec |
| `internal/enablement` | per-provider dispatch (Path A/B/C) + result table |
| `internal/targeting` | `--target-accounts` resolution (current / org-management / account-id-list AssumeRole) |
