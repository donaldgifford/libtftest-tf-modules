# Asymmetric KMS signing key for cosign (DESIGN-0031 / IMPL-0027).
#
# One instance per signing class: one key for intake's mirror
# signatures, one per CI system for first-party images. Name them with
# placeholders (example-mirror-signing), never internal programme names.

resource "aws_kms_key" "this" {
  description              = "cosign signing key (${var.name})"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = var.key_spec

  # Asymmetric keys cannot rotate: real AWS rejects EnableKeyRotation on
  # them. LocalStack 4.4 ACCEPTS it, so this pin is asserted at plan and
  # never trusted to the apply tier. Rotation means a new key plus an
  # overlap period in which verifiers trust both public keys.
  enable_key_rotation = false

  # The guard against an accidental destroy: a deleted signing key makes
  # every signature it produced unverifiable. Thirty days (the maximum)
  # is the window to cancel the deletion. There is deliberately no
  # prevent_destroy (IMPL-0027 Phase 3 build note): it would make the
  # Community apply suite's teardown impossible, and lifecycle arguments
  # are static, so it cannot be test-only.
  deletion_window_in_days = 30

  policy = local.key_policy_json

  # KMS refuses a policy that would lock the caller out of PutKeyPolicy.
  # Kept explicit so nobody "fixes" an apply error by flipping it.
  bypass_policy_lockout_safety_check = false

  lifecycle {
    # The key policy has no root delegation, so if the applying role is
    # not an admin, the very next apply could not update the policy.
    precondition {
      condition     = contains(local.admin_keys, local.caller_key)
      error_message = "admin_principal_arns must include the principal applying this module (${local.caller_arn}). The key policy delegates nothing to account IAM, so without it the deploy role is locked out of the key on the next apply."
    }
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
