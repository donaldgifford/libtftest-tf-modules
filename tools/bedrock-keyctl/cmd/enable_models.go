package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/enablement"
)

func newEnableModelsCmd(g *GlobalOptions) *cobra.Command {
	var (
		modelsArg      string
		targetAccounts string
	)

	cmd := &cobra.Command{
		Use:   "enable-models",
		Short: "Enable per-provider Bedrock model access",
		Long: "enable-models dispatches each model to its provider's enablement path:\n" +
			"Anthropic submits the one-time use-case form (idempotent), Amazon is a\n" +
			"no-op (auto-enabled), and third-party Marketplace providers subscribe\n" +
			"(Phase 17). Results print as a table. --target-accounts selects the\n" +
			"cross-account strategy; only 'current' is wired (cross-account modes land\n" +
			"in Phase 18).",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()

			specs, err := parseModelsFlag(modelsArg)
			if err != nil {
				return err
			}

			if targetAccounts != "current" {
				return fmt.Errorf(
					"--target-accounts=%q not yet supported; cross-account targeting lands in Phase 18 (use \"current\")",
					targetAccounts)
			}

			cfg, err := loadAWSConfig(ctx, g.Region)
			if err != nil {
				return err
			}

			results := enablement.NewEnabler(awsapi.NewBedrockClient(&cfg)).EnableAll(ctx, specs)
			if perr := enablement.PrintResults(cmd.OutOrStdout(), results); perr != nil {
				return perr
			}
			return enablement.FirstFailure(results)
		},
	}

	f := cmd.Flags()
	f.StringVar(&modelsArg, "models", "",
		"comma-separated <provider>.<model_id> pairs, or @file.json (required)")
	f.StringVar(&targetAccounts, "target-accounts", "current",
		"cross-account targeting: current | org-management | <account-id-list> (Phase 18)")
	cobra.CheckErr(cmd.MarkFlagRequired("models"))

	return cmd
}

// parseModelsFlag turns the --models flag into ModelSpecs. A leading '@'
// reads a JSON file; otherwise the value is a comma-separated CSV list.
func parseModelsFlag(raw string) ([]enablement.ModelSpec, error) {
	if path, ok := strings.CutPrefix(raw, "@"); ok {
		data, err := os.ReadFile(path) //nolint:gosec // operator-supplied path on a local CLI
		if err != nil {
			return nil, fmt.Errorf("read models file %s: %w", path, err)
		}
		return enablement.ParseModelsJSON(data)
	}
	return enablement.ParseModelsCSV(raw)
}
