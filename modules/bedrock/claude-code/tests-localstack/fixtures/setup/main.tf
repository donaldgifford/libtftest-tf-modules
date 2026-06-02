# Minimal LocalStack fixture for the bedrock/claude-code module.
#
# Unlike the EKS/EFS modules, this module reads NO upstream remote
# state (Bedrock is fleet-shared; there is no VPC or cluster to compose
# with). The fixture therefore creates only a single S3 bucket — a stub
# that proves the LocalStack apply path works for an available
# Community service before the gap-discovery plan_smoke runs against
# the module proper. S3 is one of the few services this module's
# dependency set shares with LocalStack Community coverage.

variable "stub_bucket" {
  description = "Name of the stub S3 bucket created so the LocalStack apply path is exercised against an available Community service."
  type        = string
}

resource "aws_s3_bucket" "stub" {
  bucket        = var.stub_bucket
  force_destroy = true
}
