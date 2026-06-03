// Package cmd wires the bedrock-keyctl cobra command tree. The root
// command owns global flags (--region, --log-level, --dry-run); the
// mint/rotate/revoke/enable-models subcommands land in Phases 13-18.
package cmd

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"
)

// GlobalOptions are the root-level flags shared by every subcommand.
type GlobalOptions struct {
	// Region overrides the AWS region the SDK resolves. Empty means use
	// the SDK's default resolution chain.
	Region string
	// LogLevel is the verbosity: debug, info, warn, or error.
	LogLevel string
	// DryRun prints intended actions without calling AWS mutating APIs.
	DryRun bool
}

var validLogLevels = map[string]bool{
	"debug": true,
	"info":  true,
	"warn":  true,
	"error": true,
}

// validate checks the parsed global options.
func (o *GlobalOptions) validate() error {
	if !validLogLevels[o.LogLevel] {
		return fmt.Errorf("invalid --log-level %q: want one of debug, info, warn, error", o.LogLevel)
	}
	return nil
}

// Execute builds the root command and runs it, returning a process exit
// code. The context is cancelled on SIGINT/SIGTERM so long operations
// (the rotate grace-period sleep) are interruptible.
func Execute() int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := newRootCmd().ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	return 0
}

// newRootCmd assembles the root command and its global flags.
func newRootCmd() *cobra.Command {
	opts := &GlobalOptions{}

	cmd := &cobra.Command{
		Use:   "bedrock-keyctl",
		Short: "Manage Bedrock bearer-token credentials and model-access enablement",
		Long: "bedrock-keyctl mints, rotates, and revokes the IAM service-specific\n" +
			"credential Claude Code consumes via AWS_BEARER_TOKEN_BEDROCK, and enables\n" +
			"Bedrock model access per provider. The credential secret never touches\n" +
			"Terraform state or stdout — it is written only to a secret sink.",
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRunE: func(_ *cobra.Command, _ []string) error {
			return opts.validate()
		},
	}

	pf := cmd.PersistentFlags()
	pf.StringVar(&opts.Region, "region", "", "AWS region (defaults to the SDK's resolved region)")
	pf.StringVar(&opts.LogLevel, "log-level", "info", "log verbosity: debug, info, warn, error")
	pf.BoolVar(&opts.DryRun, "dry-run", false, "print intended actions without calling AWS mutating APIs")

	cmd.AddCommand(newMintCmd(opts))
	// rotate/revoke/enable-models land in Phases 14-18.

	return cmd
}
