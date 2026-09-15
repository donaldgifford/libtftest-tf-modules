# Policy composition suite (IMPL-0028 2.2 — statement-by-statement
# from jsondecode(bucket_policy_json), never string matching).
#
# Collapse discipline (the IMPL-0022 rendering gotcha):
# aws_iam_policy_document collapses single-element sets, so Principal,
# Action, Resource, and Condition values are STRINGS at cardinality 1
# and LISTS above it. Both cardinalities are pinned (the two-endpoints
# run); every other run asserts the single-element string shape, which
# is what the default invocation renders.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                        = "mirror"
  vpc_endpoint_ids            = ["vpce-0123456789abcdef0"]
  policy_admin_principal_arns = ["arn:aws:iam::000000000000:role/admin"]
}

# P0 (IMPL-0025 Phase 1.7): the star principal renders through the
# injection channel.
run "probe_p0_star_principal" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowMirrorReadFromVPCE"]).Principal == "*"
    error_message = "P0: AllowMirrorReadFromVPCE must render Principal \"*\" from principals = { \"*\" = [\"*\"] }"
  }
}

# The allow, in full: GetObject only, objects only, VPCE-conditioned.
run "allow_read_detail" {
  command = plan

  assert {
    condition = alltrue([
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowMirrorReadFromVPCE"]).Action == "s3:GetObject",
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowMirrorReadFromVPCE"]).Resource == "arn:aws:s3:::mirror-000000000000-us-east-1/*",
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowMirrorReadFromVPCE"]).Condition.StringEquals["aws:SourceVpce"] == "vpce-0123456789abcdef0",
    ])
    error_message = "AllowMirrorReadFromVPCE must be GetObject-only on objects-only, conditioned on exactly var.vpc_endpoint_ids"
  }
}

# Cardinality 2: the same condition renders a LIST — assert as a set
# (toset on a bare string is a conversion error, so this run
# self-defends against the single-element collapse).
run "two_endpoints_list_shape" {
  command = plan

  variables {
    vpc_endpoint_ids = ["vpce-0123456789abcdef0", "vpce-abcdef0123456789a"]
  }

  assert {
    condition     = toset(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowMirrorReadFromVPCE"]).Condition.StringEquals["aws:SourceVpce"]) == toset(["vpce-0123456789abcdef0", "vpce-abcdef0123456789a"])
    error_message = "two endpoints must render both VPCE ids as a condition list (no collapse, no loss)"
  }
}

# Baseline + backstop denies render beside the mirror statements.
run "baseline_denies_present" {
  command = plan

  assert {
    condition = alltrue([
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyInsecureTransport"),
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyOldTls"),
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyOutsideVpce"),
    ])
    error_message = "the TLS baseline denies and the VPCE backstop deny must render beside the mirror statements"
  }
}

# Default break-glass (empty): the delete-deny carries NO Condition
# key at all — absolute deny (an empty values list is invalid IAM,
# so the block is count-gated away, not rendered empty).
run "delete_deny_absolute" {
  command = plan

  assert {
    condition = alltrue([
      !can(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyObjectDeletion"]).Condition),
      toset(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyObjectDeletion"]).Action) == toset(["s3:DeleteObject", "s3:DeleteObjectVersion"]),
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyObjectDeletion"]).Principal == "*",
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyObjectDeletion"]).Resource == "arn:aws:s3:::mirror-000000000000-us-east-1/*",
    ])
    error_message = "empty break_glass_principal_arns must render an unconditional delete-deny (no Condition key) over both delete actions on objects"
  }
}

# Non-empty break-glass: the exemption condition renders.
run "delete_deny_break_glass" {
  command = plan

  variables {
    break_glass_principal_arns = ["arn:aws:iam::000000000000:role/break-glass"]
  }

  assert {
    condition     = one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyObjectDeletion"]).Condition.StringNotEquals["aws:PrincipalArn"] == "arn:aws:iam::000000000000:role/break-glass"
    error_message = "non-empty break_glass_principal_arns must render the StringNotEquals aws:PrincipalArn exemption"
  }
}

# Mutation guard, default on: scoped to the admin list, bucket ARN.
run "mutation_guard_conditional" {
  command = plan

  assert {
    condition = alltrue([
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyPolicyMutation"]).Condition.StringNotEquals["aws:PrincipalArn"] == "arn:aws:iam::000000000000:role/admin",
      toset(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyPolicyMutation"]).Action) == toset(["s3:PutBucketPolicy", "s3:DeleteBucketPolicy"]),
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyPolicyMutation"]).Resource == "arn:aws:s3:::mirror-000000000000-us-east-1",
    ])
    error_message = "DenyPolicyMutation must scope PutBucketPolicy/DeleteBucketPolicy on the bucket ARN to outside the admin list"
  }
}

# Mutation guard, off: the sid vanishes entirely. The discrimination
# pair for the run above — a rejection-only suite stays green whether
# the gate discriminates or drops everything.
run "mutation_guard_disabled" {
  command = plan

  variables {
    enable_policy_mutation_guard = false
  }

  assert {
    condition     = !contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyPolicyMutation")
    error_message = "enable_policy_mutation_guard = false must remove the DenyPolicyMutation statement (and nothing else is asserted here)"
  }
}

# Publisher allow: absent by default (same-account needs no grant).
run "publisher_absent_default" {
  command = plan

  assert {
    condition     = !contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "AllowCrossAccountPublisherWrite")
    error_message = "no publisher statement may render without cross_account_publisher_principal_arns"
  }
}

# Publisher allow: write-only-no-delete, scoped to this bucket.
run "publisher_rendered" {
  command = plan

  variables {
    cross_account_publisher_principal_arns = ["arn:aws:iam::111122223333:role/publisher"]
  }

  assert {
    condition = alltrue([
      one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowCrossAccountPublisherWrite"]).Principal.AWS == "arn:aws:iam::111122223333:role/publisher",
      toset(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowCrossAccountPublisherWrite"]).Action) == toset(["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]),
      toset(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowCrossAccountPublisherWrite"]).Resource) == toset(["arn:aws:s3:::mirror-000000000000-us-east-1", "arn:aws:s3:::mirror-000000000000-us-east-1/*"]),
    ])
    error_message = "the publisher grant must be write-only-no-delete on this bucket only, naming exactly the declared principal"
  }
}

# Additive merge: operator statements coexist; nothing shadowed.
run "additive_merge" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid        = "AllowOpsAudit"
      principals = { AWS = ["arn:aws:iam::000000000000:role/ops-audit"] }
      actions    = ["s3:GetObject"]
    }]
  }

  assert {
    condition = alltrue([
      for sid in ["DenyInsecureTransport", "DenyOldTls", "DenyOutsideVpce", "AllowMirrorReadFromVPCE", "DenyObjectDeletion", "DenyPolicyMutation", "AllowOpsAudit"] :
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], sid)
    ])
    error_message = "operator statements must append beside the intact baseline + mirror statements (additive-only merge)"
  }
}
