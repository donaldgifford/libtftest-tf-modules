plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled    = true
  version    = "0.47.0"
  source     = "github.com/terraform-linters/tflint-ruleset-aws"
  deep_check = false
}

plugin "terraform-style" {
  enabled = true

  # Specify version if using a remote source
  version = "0.0.5"
  source  = "github.com/donaldgifford/tflint-ruleset-terraform-style"
}
