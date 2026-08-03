# S3 security core (modules/s3/internal/core)
#
# INTERNAL MODULE — not independently consumable. This is the shared
# security core of the modules/s3/ family (DESIGN-0019 / INV-0009 OQ 1c):
# the purpose modules (access-logs-bucket, bucket, events-bucket) consume
# it ONLY via the relative path `source = "../internal/core"`, so it rides
# each purpose module's release tag and has no independent version to
# drift. It must NEVER gain a versioned source (registry or git-ref) — if
# it ever does, the DESIGN-0019 nesting exemption is void.
#
# Owns the bucket and every baseline companion resource: composed naming
# (+ opt-in shard prefix), Block Public Access, BucketOwnerEnforced,
# SSE (KMS default / S3 for the access-logs sink), versioning, lifecycle
# hygiene, the composed bucket policy (TLS denies + opt-in VPCE-only +
# purpose-module statement injection), and server-access-logging wiring.
# Remote-state reads stay in the purpose modules (read-at-use-site;
# ADR-0020 assertions need a root-module data source).
