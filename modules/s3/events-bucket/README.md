<!-- markdownlint-disable-file MD025 MD041 -->
# S3 Events Bucket

Everything [`s3/bucket`](../bucket) is — the F2 security baseline from
the family's internal core, the F4 access-logging tri-state, the six
Terragrunt globals, additive operator policy statements — **plus a
notification configuration**
([DESIGN-0019](../../../docs/design/0019-s3-module-family-internal-core-and-initial-bucket-modules.md)
Phase 4).

Use this module when the bucket must emit events; use `s3/bucket`
when it must not. There is no "notifications off" mode here — a
precondition requires at least one destination, because an events
bucket with nowhere to send events is a misconfiguration rather than
a valid intermediate state.

See [USAGE.md](USAGE.md) for the generated input / output reference,
and `s3/bucket`'s README for the shared surface (tri-state,
ADR-0020 contract, additional policy statements) — it applies verbatim
here.

## Destinations

`aws_s3_bucket_notification` is a **per-bucket singleton**: the AWS API
replaces the entire notification configuration on every write, so two
resources pointing at one bucket silently clobber each other. All
destinations therefore live in one resource in this module.

```hcl
module "events" {
  source = "../../s3/events-bucket"

  name       = "app-events"
  account_id = var.account_id
  region     = var.region
  # ... the six Terragrunt globals ...

  sqs_queues = [{
    id            = "raw-uploads"          # unique per bucket
    arn           = module.queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "incoming/"            # optional, per entry
    filter_suffix = ".json"                # optional, per entry
  }]

  sns_topics = [{
    id     = "fanout"
    arn    = module.topic.arn
    events = ["s3:ObjectRemoved:*"]
  }]

  eventbridge_enabled = true # all events; filtering happens in EventBridge rules
}
```

Any one of the three satisfies the at-least-one-destination
requirement. Filters are **per entry**, not global.

## Destination policies are NOT owned by this module

S3 delivers notifications using its own service principal, so each
destination must grant it. That grant belongs to the **destination's**
stack — this module only registers the wiring. The required shape for
an SQS queue:

```hcl
data "aws_iam_policy_document" "queue" {
  statement {
    sid    = "AllowS3BucketNotifications"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:s3:::<the events bucket's composed name>"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}
```

An SNS topic needs the equivalent `sns:Publish` policy. Real S3
**rejects** a notification configuration whose destination does not
grant it (`InvalidArgument: Unable to validate the following
destination configurations`) — so a missing policy fails the apply in
production. LocalStack does not enforce this (see
[FINDINGS.md](tests-localstack/FINDINGS.md)), which is why the apply
fixture demonstrates the policy rather than proving it.

`tests-localstack/fixtures/destinations/main.tf` is the worked example.

## Tests

| Suite | Tier | What it proves |
|-------|------|----------------|
| `tests/` (13 runs) | plan-only, the CI gate | the notification singleton's shape (single destination, all three kinds at once, per-entry filters, EventBridge-only), the destination requirement, unique-id and non-empty-event guards, plus the inherited tri-state / ADR-0020 key / policy / naming coverage |
| `tests-localstack/` (3 runs) | Community apply (token-free `localstack/localstack:4.4`, `SERVICES=s3,sts,sqs,sns,events`) | notifications and the reserved-key lookup applied for real against SQS + SNS + EventBridge; see [FINDINGS.md](tests-localstack/FINDINGS.md) including the **positive** F6 probe on notification firing |

`security_baseline.tftest.hcl` is byte-identical to `s3/bucket`'s
(guarded by a `diff -q` check in the static gate).
