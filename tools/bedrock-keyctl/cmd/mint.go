package cmd

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/sink"
)

// mintDeps are the injected collaborators for runMint, so the core
// logic is testable against mocks without touching AWS.
type mintDeps struct {
	iam  awsapi.IAMClient
	sink sink.Sink
	out  io.Writer
}

// mintRequest is the parsed, validated input for a mint.
type mintRequest struct {
	user       string
	key        string
	expiryDays int32
	dryRun     bool
}

func newMintCmd(g *GlobalOptions) *cobra.Command {
	var (
		user       string
		expiryDays int32
		sinkURI    string
	)

	cmd := &cobra.Command{
		Use:   "mint",
		Short: "Mint a Bedrock bearer-token credential and write it to a sink",
		Long: "mint creates a new IAM service-specific credential for\n" +
			"bedrock.amazonaws.com on the given user, writes the one-time secret to\n" +
			"the configured sink as a JSON envelope, and prints the credential ID\n" +
			"and expiry. The secret itself is never printed.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()

			cfg, err := loadAWSConfig(ctx, g.Region)
			if err != nil {
				return err
			}

			s, key, err := sink.ParseURI(sinkURI, &cfg)
			if err != nil {
				return err
			}

			return runMint(ctx, mintDeps{
				iam:  awsapi.NewIAMClient(&cfg),
				sink: s,
				out:  cmd.OutOrStdout(),
			}, mintRequest{
				user:       user,
				key:        key,
				expiryDays: expiryDays,
				dryRun:     g.DryRun,
			})
		},
	}

	f := cmd.Flags()
	f.StringVar(&user, "user", "", "IAM user to mint the credential on (required)")
	f.Int32Var(&expiryDays, "expiry-days", 90, "credential lifetime in days")
	f.StringVar(&sinkURI, "sink", "", "secret sink URI, e.g. sm://<secret-name> (required)")
	cobra.CheckErr(cmd.MarkFlagRequired("user"))
	cobra.CheckErr(cmd.MarkFlagRequired("sink"))

	return cmd
}

// runMint mints a credential and writes it to the sink. It never prints
// the secret — only the credential ID and expiry.
func runMint(ctx context.Context, d mintDeps, r mintRequest) error {
	if r.dryRun {
		_, err := fmt.Fprintf(d.out, "[dry-run] would mint a Bedrock credential for user %q (expiry %d days) and write it to the sink\n", r.user, r.expiryDays)
		return err
	}

	cred, err := d.iam.CreateCredential(ctx, r.user, r.expiryDays)
	if err != nil {
		return fmt.Errorf("mint credential: %w", err)
	}

	if err := sink.WriteCredential(ctx, d.sink, r.key, cred.ID, cred.Secret, cred.ExpiresAt); err != nil {
		return err
	}

	_, err = fmt.Fprintf(d.out, "minted credential %s for user %s (%s)\n", cred.ID, cred.UserName, formatExpiry(cred.ExpiresAt))
	return err
}

// formatExpiry renders a credential expiry for human output.
func formatExpiry(expiresAt time.Time) string {
	if expiresAt.IsZero() {
		return "no expiry set"
	}
	return "expires " + expiresAt.UTC().Format(time.RFC3339)
}
