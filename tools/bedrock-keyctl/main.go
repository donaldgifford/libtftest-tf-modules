// Command bedrock-keyctl manages the IAM service-specific credential
// Claude Code consumes via AWS_BEARER_TOKEN_BEDROCK for Amazon Bedrock,
// and enables Bedrock model access per provider (DESIGN-0009 / RFC-0003).
package main

import (
	"os"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/cmd"
)

func main() {
	os.Exit(cmd.Execute())
}
