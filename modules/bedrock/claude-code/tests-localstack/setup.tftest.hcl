# LocalStack fixture bring-up per IMPL-0009 Phase 10.
#
# The bedrock/claude-code module reads no upstream remote state, so the
# fixture is the simplest possible: a single S3 bucket, applied against
# LocalStack to prove the apply path reaches an available Community
# service. The module's own gap-discovery runs live in
# apply_localstack.tftest.hcl.
#
# Required env vars (the `just tf test-localstack` recipe wires these):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "http://s3.localhost.localstack.cloud:4566"
  }
}

variables {
  region        = "us-east-1"
  cost_tag      = { key = "Team", value = "tftest-bedrock" }
  budget_amount = 100
}

run "setup" {
  command = apply

  variables {
    stub_bucket = "tftest-bedrock-claude-code-stub"
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }

  assert {
    condition     = aws_s3_bucket.stub.bucket == "tftest-bedrock-claude-code-stub"
    error_message = "LocalStack apply path must create the stub S3 bucket"
  }
}
