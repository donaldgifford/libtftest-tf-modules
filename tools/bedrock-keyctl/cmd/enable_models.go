package cmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/spf13/cobra"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/enablement"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/targeting"
)

const sessionName = "bedrock-keyctl-enable-models"

func newEnableModelsCmd(g *GlobalOptions) *cobra.Command {
	var (
		modelsArg      string
		targetAccounts string
		subscribePath  string
		assumeRoleName string
	)

	cmd := &cobra.Command{
		Use:   "enable-models",
		Short: "Enable per-provider Bedrock model access",
		Long: "enable-models dispatches each model to its provider's enablement path:\n" +
			"Anthropic submits the one-time use-case form (idempotent), Amazon is a\n" +
			"no-op (auto-enabled), and third-party Marketplace providers subscribe.\n" +
			"--target-accounts selects the cross-account strategy: current (this\n" +
			"account), org-management (Anthropic cascades to members; other providers\n" +
			"warn), or a comma-separated list of 12-digit account IDs (AssumeRole into\n" +
			"each). Results print as a per-account table.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()

			specs, err := parseModelsFlag(modelsArg)
			if err != nil {
				return err
			}

			path := enablement.SubscribePath(subscribePath)
			if !enablement.ValidSubscribePath(path) {
				return fmt.Errorf(
					"--marketplace-subscribe-path=%q invalid; want auto, explicit, or invocation", subscribePath)
			}

			cfg, err := loadAWSConfig(ctx, g.Region)
			if err != nil {
				return err
			}

			targets, err := targeting.ResolveTargets(
				ctx, awsapi.NewSTSClient(&cfg), targetAccounts, assumeRoleName, sessionName)
			if err != nil {
				return err
			}

			return dispatchTargets(ctx, &cfg, cmd.OutOrStdout(), targets, specs, path)
		},
	}

	f := cmd.Flags()
	f.StringVar(&modelsArg, "models", "",
		"comma-separated <provider>.<model_id> pairs, or @file.json (required)")
	f.StringVar(&targetAccounts, "target-accounts", targeting.ModeCurrent,
		"cross-account targeting: current | org-management | <account-id-list>")
	f.StringVar(&subscribePath, "marketplace-subscribe-path", string(enablement.SubscribeAuto),
		"Path C sub-path: auto | explicit | invocation")
	f.StringVar(&assumeRoleName, "assume-role-name", "bedrock-enablement",
		"role name to AssumeRole into for each account in an <account-id-list> target")
	cobra.CheckErr(cmd.MarkFlagRequired("models"))

	return cmd
}

// dispatchTargets runs the per-provider enablement dispatch against every
// target, printing a per-account result table. It returns the first
// failure (if any) after all targets are processed, so one account's
// error does not abort the rest.
func dispatchTargets(ctx context.Context, base *aws.Config, out io.Writer, targets []targeting.Target, specs []enablement.ModelSpec, path enablement.SubscribePath) error {
	var failed error
	for i := range targets {
		t := targets[i]

		cfg := *base
		if t.Credentials != nil {
			cfg = configForCredentials(base, *t.Credentials)
		}

		logf(out, "== account %s ==\n", t.AccountID)
		enabler := enablement.NewEnabler(
			awsapi.NewBedrockClient(&cfg), awsapi.NewMarketplaceClient(&cfg), path)
		results := enabler.EnableAllForTarget(ctx, specs, t.CascadeOnlyAnthropic)

		if perr := enablement.PrintResults(out, results); perr != nil {
			return perr
		}
		if ferr := enablement.FirstFailure(results); ferr != nil && failed == nil {
			failed = ferr
		}
	}
	return failed
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
