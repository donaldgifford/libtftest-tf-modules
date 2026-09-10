# Trust conditions — DESIGN-0027 Part A (IMPL-0024 tasks 1.5/1.6).
#
# RENDERING, PROBED NOT ASSUMED (task 1.4). Three facts drive every
# assertion below; each was read out of the real rendered document
# before a single one was written:
#
#   1. Unset inputs render NO "Condition" key at all — not an empty
#      map. That is the zero-diff invariant against v0.23.0.
#   2. Condition `values` collapse exactly like Principal.AWS: ONE
#      org id renders a bare STRING, two render a LIST. An assertion
#      written for one cardinality proves nothing about the other,
#      which is why both are pinned — the multi-org case is the
#      whole point of the list (DESIGN-0027 OQ 1b).
#   3. Two conditions sharing the SAME test operator MERGE into one
#      "StringEquals" object with two variable keys. They are NOT two
#      entries under Condition. So the AND invariant is asserted as
#      "StringEquals carries both keys", and `length(Condition) == 2`
#      would be simply false.
#
# IAM combines all three of these as AND — values within one
# condition OR, conditions AND, statements OR — so the statement
# count is pinned at 1 in every run here. See trust.tf.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name              = "conditions-role"
  trusted_role_arns = ["arn:aws:iam::000000000000:role/hub-argocd-deployer"]
}

# THE ZERO-DIFF RUN. Pinned first, like the S3 family's default runs:
# iam/role shipped as v0.23.0 and every existing invocation must
# render the identical trust document. Asserting an EMPTY condition
# map would pass on a document rendering "Condition": {}, which is a
# different document — so this asserts the key is absent entirely.
run "no_conditions_renders_no_condition_key" {
  command = plan

  assert {
    condition     = !contains(keys(one(jsondecode(aws_iam_role.this.assume_role_policy).Statement)), "Condition")
    error_message = "an invocation setting neither condition input must render NO Condition key — anything else churns the trust policy of every role that shipped in v0.23.0"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "the trust document must stay a single statement"
  }
}

# ONE org id: the value collapses to a bare string.
run "single_org_id_renders_a_string" {
  command = plan

  variables {
    require_org_ids = ["o-a1b2c3d4e5"]
  }

  assert {
    condition     = one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals["aws:PrincipalOrgID"] == "o-a1b2c3d4e5"
    error_message = "a single org id must render as the bare StringEquals value on aws:PrincipalOrgID"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "adding a condition must not add a statement — a second statement would OR, not AND"
  }
}

# TWO org ids: the same key now carries a LIST. This is the run that
# stops the single-org assertion above from being the only evidence —
# it passes on a string and would say nothing about the list.
run "two_org_ids_render_a_list" {
  command = plan

  variables {
    require_org_ids = ["o-a1b2c3d4e5", "o-f6g7h8i9j0"]
  }

  assert {
    condition = toset(one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals["aws:PrincipalOrgID"]) == toset([
      "o-a1b2c3d4e5",
      "o-f6g7h8i9j0",
    ])
    error_message = "both organizations must reach the condition, and nothing else may — StringEquals ORs these values, which is the intended \"in any of our orgs\""
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "a second org must not add a statement"
  }
}

run "external_id_alone" {
  command = plan

  variables {
    external_id = "hub-to-spoke-42"
  }

  assert {
    condition     = one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals["sts:ExternalId"] == "hub-to-spoke-42"
    error_message = "external_id must render as StringEquals on sts:ExternalId"
  }

  assert {
    condition     = !contains(keys(one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals), "aws:PrincipalOrgID")
    error_message = "an unset require_org_ids must contribute no condition key"
  }
}

# THE AND INVARIANT. Both conditions must live in ONE statement:
# conditions AND, statements OR, so a refactor splitting them would
# silently turn "in our org AND presenting the external id" into
# "... OR ...". This run is what catches that — note the merged
# StringEquals shape (probe finding 3), which is why the assertion
# counts keys inside StringEquals rather than under Condition.
run "both_conditions_and_within_one_statement" {
  command = plan

  variables {
    require_org_ids = ["o-a1b2c3d4e5"]
    external_id     = "hub-to-spoke-42"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "both conditions must compose into ONE statement — separate statements are OR-ed by IAM, which would let either condition alone grant the assume"
  }

  assert {
    condition = toset(keys(one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals)) == toset([
      "aws:PrincipalOrgID",
      "sts:ExternalId",
    ])
    error_message = "both condition keys must land in the one StringEquals block, where IAM ANDs them"
  }

  assert {
    condition     = toset(keys(one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition)) == toset(["StringEquals"])
    error_message = "both conditions share the StringEquals operator, so exactly one operator block may render"
  }
}
