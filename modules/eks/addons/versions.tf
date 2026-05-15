#--------------------------------------------------------------
# Provider Versions
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.1"

  required_providers {
    # tflint-ignore: terraform_unused_required_providers  # consumed in a later IMPL-0003 phase
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
