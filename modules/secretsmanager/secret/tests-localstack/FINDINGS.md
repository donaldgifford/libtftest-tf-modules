# LocalStack findings — secretsmanager/secret Community apply suite

Suite: `apply_localstack.tftest.hcl` (4 runs) — **run and passing 4/4**
against token-free `localstack/localstack:4.4`,
`SERVICES=secretsmanager,sts` (2026-08-12). Community tier: no Pro, no
auth token, no named volume.

## What the suite proves live

- The write-only path applies: `secret_string_wo` creates a version
  staged `AWSCURRENT` (the versions-check fixture reads
  `aws_secretsmanager_secret_versions` — plural, metadata-only — never
  the singular value-bearing data source, per DESIGN-0020 OQ 6a).
- **The F4 rotation mechanism, end to end (OQ 2a):** bumping
  `secret_string_version` 1 → 2 replaced the `AWSCURRENT` version id
  (`verify_rotated` asserts the id changed vs `verify_current`). One
  bump = one new password = a new current version.
- Pointer outputs are real: `secret_arn` is a well-formed SM ARN
  embedding the `name_prefix`, `kms_key_arn` is faithfully null on the
  managed-key path, `username` echoes.
- `secret_recovery_window_days = 0` teardown actually deletes:
  `list-secrets` is empty after the suite.

## Parity probes

- **Name-reuse reservation: POSITIVE.** LocalStack 4.4 emulates the
  recovery-window name lock: create → delete with
  `--recovery-window-in-days 7` → recreate same name fails with the
  real API's error (`InvalidRequestException: You can't create this
  secret because a secret with this name is already scheduled for
  deletion.`). So the module's `name_prefix` rationale (DESIGN-0020
  resolution 5a) is exercised faithfully even against the emulator, and
  suites that forget the window-0 teardown would brick their own
  recreate — another reason it stays in this suite's `variables`.
- **Version-stage retention: not hard-asserted.** The fixture exposes
  `version_count` informationally only; the suite pins the
  AWSCURRENT-id-changed proof and deliberately does not assert how many
  historical versions (AWSPREVIOUS etc.) the emulator retains — that
  detail is emulator-specific and irrelevant to the F4 mechanism.

## Environment notes

- The `just tf test-localstack` recipe wires `AWS_ENDPOINT_URL` /
  fake keys / region; the provider block additionally pins
  `endpoints { secretsmanager, sts }` at `http://localhost:4566`
  (fleet convention).
- Gotcha (local dev): a module previously initialized with
  `TF_PLUGIN_CACHE_DIR` (e.g. by `scripts/static-check.sh`) leaves
  SYMLINKED provider dirs; the recipe's cache-less `terraform init`
  then fails with "cannot install package into target directory …
  because it is a symlink". Fix: `rm -rf .terraform .terraform.lock.hcl`
  in the module and re-run.

## DESIGN-0029 / IMPL-0026 — provider `default_tags` (2026-11-11)

The module no longer declares a `tags` input. The standard tag set
arrives through the provider's `default_tags`, which this suite's
provider block now sets (`ManagedBy`, `Suite`), so the apply
exercises the real tagging path.

- **Image:** token-free `localstack/localstack:4.4` (Community 4.4.0),
  no auth token.
- **Services:** one container for all eight Community suites in this
  IMPL, with `SERVICES=iam,sts,ec2,s3,sqs,sns,events,secretsmanager`.
  That is a superset of this suite's recorded list.
- **Result:** 4/4 green.

`verify_current` now also asserts the `default_tags` pair reads back through `data.aws_secretsmanager_secret`, the metadata data source, which carries no secret value. OQ 6a holds (IMPL-0026 3.4). Mutation-checked live: dropping the provider's `default_tags` reds exactly that assert.
