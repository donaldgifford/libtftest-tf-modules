# Policy composition probes (IMPL-0025 Phase 1.7 P0 first).
#
# Probe P0: no family suite has ever sent principals = { "*" = ["*"] }
# through the injection channel. This run proves
# aws_iam_policy_document renders Principal "*" from that shape at
# plan. (Phase 2 grows this file into the full statement-by-statement
# suite.)

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

# P0: the star principal renders.
run "probe_p0_star_principal" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowMirrorReadFromVPCE"]).Principal == "*"
    error_message = "P0: AllowMirrorReadFromVPCE must render Principal \"*\" from principals = { \"*\" = [\"*\"] }"
  }
}
