# Trust composition — the two platform DESIGN-0025 §4 shapes
# (IMPL-0022 task 1.6).
#
# Real-provider-fake-creds, no mock_provider: aws_iam_policy_document
# evaluates LOCALLY, so the composed assume_role_policy is plan-known
# and asserted by CONTENT via jsondecode — never by reference.
#
# RENDERING GOTCHA (probed, not assumed): aws_iam_policy_document
# collapses single-element sets. With ONE principal, Principal.AWS is
# a STRING; with two or more it is a LIST. Likewise Action is a bare
# string here because the statement has exactly one action. The two
# runs below cover both spellings on purpose — an assertion written
# for one shape silently passes nothing on the other.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

# Shape 1: the per-account deploy role — trusted by the hub
# automation principals, carrying the account's deploy policy. This
# is the role every ADR-0020 assume_role block names.
run "deploy_shaped" {
  command = plan

  variables {
    name        = "deploy-tf"
    description = "Terraform deploy role assumed by hub automation"

    trusted_role_arns = [
      "arn:aws:iam::000000000000:role/atlantis-pod-identity",
      "arn:aws:iam::000000000000:role/argocd-deployer",
    ]

    managed_policy_arns          = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    customer_managed_policy_arns = ["arn:aws:iam::000000000000:policy/deploy-tf"]
  }

  assert {
    condition     = aws_iam_role.this.name == "deploy-tf"
    error_message = "the role name must be the caller's value verbatim — no prefix, no suffix (the by-name contract)"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "the trust policy must compose exactly one statement"
  }

  assert {
    condition     = one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Effect == "Allow"
    error_message = "the trust statement must Allow"
  }

  assert {
    condition     = one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Action == "sts:AssumeRole"
    error_message = "the trust statement must grant exactly sts:AssumeRole (no TagSession — that is the pod-identity path's)"
  }

  # Two principals => Principal.AWS is a list.
  assert {
    condition = toset(one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Principal.AWS) == toset([
      "arn:aws:iam::000000000000:role/atlantis-pod-identity",
      "arn:aws:iam::000000000000:role/argocd-deployer",
    ])
    error_message = "every trusted_role_arns entry must reach the composed trust policy, and nothing else may"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 1 && length(aws_iam_role_policy_attachment.customer) == 1
    error_message = "the AWS-owned and caller-owned channels must attach independently"
  }

  assert {
    condition     = length(aws_iam_role_policy.inline) == 0
    error_message = "no inline policy resource may exist when inline_policies is empty"
  }
}

# Shape 2: sse-platform-access — trusted by the hub argocd-deployer
# pod-identity role, carrying a scoped inline document. The
# CLUSTER-side half of this pattern is an eks/access-entries entry
# (DESIGN-0024), not this module's concern.
run "platform_access_shaped" {
  command = plan

  variables {
    name        = "sse-platform-access"
    description = "Assumed by the hub argocd-deployer to reach this spoke's cluster"

    trusted_role_arns = ["arn:aws:iam::000000000000:role/hub-argocd-deployer"]

    inline_policies = {
      eks-describe = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["eks:DescribeCluster", "eks:ListClusters"]
          Resource = "*"
        }]
      })
    }
  }

  # ONE principal => Principal.AWS is a bare string, not a list.
  assert {
    condition     = one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Principal.AWS == "arn:aws:iam::000000000000:role/hub-argocd-deployer"
    error_message = "a single trusted principal must render as the sole AWS principal"
  }

  assert {
    condition     = length(aws_iam_role_policy.inline) == 1
    error_message = "each inline_policies entry must mint its own aws_iam_role_policy"
  }

  assert {
    condition     = aws_iam_role_policy.inline["eks-describe"].name == "eks-describe"
    error_message = "the inline policy must be addressed and named by its map key (a stable address under map edits)"
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.inline["eks-describe"].policy).Statement[0].Action, "eks:DescribeCluster")
    error_message = "the caller's inline document must pass through verbatim"
  }
}

# The BARE call — nothing set but the two required inputs, so this
# run is the only place the defaults themselves are pinned. Every
# other run overrides them, which is how "permissions_boundary has no
# default assertion anywhere" survived review (IMPL-0022 task 4.6):
# changing a default failed no test. null here is load-bearing — it is
# what makes the empty-string rejection meaningful rather than a
# stricter spelling of the same behavior.
run "bare_call_pins_defaults" {
  command = plan

  variables {
    name              = "bare-role"
    trusted_role_arns = ["arn:aws:iam::000000000000:role/atlantis-pod-identity"]
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "permissions_boundary must default to null — NO boundary argument, not an empty one"
  }

  assert {
    condition     = aws_iam_role.this.max_session_duration == 3600
    error_message = "max_session_duration must default to the AWS 1-hour default"
  }

  assert {
    condition     = aws_iam_role.this.path == "/"
    error_message = "path must default to \"/\""
  }

  assert {
    condition     = aws_iam_role.this.description == null
    error_message = "description must default to null rather than an empty string"
  }

  # tags is deliberately not asserted here: an empty map renders as
  # null on this Optional+Computed attribute at plan, so an assertion
  # would pin the provider's representation rather than the module's
  # default. The apply suite checks tags where they are real.
}

# Defaults and pass-throughs the two shapes above do not exercise.
run "defaults_and_passthrough" {
  command = plan

  variables {
    name                 = "boundary-role"
    trusted_role_arns    = ["arn:aws:iam::000000000000:role/atlantis-pod-identity"]
    permissions_boundary = "arn:aws:iam::000000000000:policy/platform-boundary"
    max_session_duration = 7200
    tags                 = { Owner = "platform" }
  }

  assert {
    condition     = aws_iam_role.this.path == "/"
    error_message = "path must default to \"/\" — the spelling eks/access-entries bindings expect"
  }

  assert {
    condition     = aws_iam_role.this.max_session_duration == 7200
    error_message = "max_session_duration must pass through"
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == "arn:aws:iam::000000000000:policy/platform-boundary"
    error_message = "permissions_boundary must pass through"
  }

  assert {
    condition     = aws_iam_role.this.tags["Owner"] == "platform"
    error_message = "tags must pass through to the role"
  }
}

# A non-default path is legal and passes through — the README's
# two-spellings caution is operational guidance, not a module rule.
run "non_default_path" {
  command = plan

  variables {
    name              = "pathed-role"
    path              = "/platform/"
    trusted_role_arns = ["arn:aws:iam::000000000000:role/atlantis-pod-identity"]
  }

  assert {
    condition     = aws_iam_role.this.path == "/platform/"
    error_message = "a non-default path must pass through verbatim"
  }
}
