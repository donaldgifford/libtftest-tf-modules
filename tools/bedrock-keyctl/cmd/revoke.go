package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/sink"
)

// revokeDeps are the injected collaborators for runRevoke. sink is nil
// when --sink is omitted (IAM-only revoke).
type revokeDeps struct {
	iam  awsapi.IAMClient
	sink sink.Sink
	key  string
	out  io.Writer
	in   io.Reader
}

// revokeRequest is the parsed, validated input for a revoke.
type revokeRequest struct {
	user         string
	credentialID string
	force        bool
	dryRun       bool
}

func newRevokeCmd(g *GlobalOptions) *cobra.Command {
	var (
		user         string
		credentialID string
		sinkURI      string
		force        bool
	)

	cmd := &cobra.Command{
		Use:   "revoke",
		Short: "Revoke a specific Bedrock credential (deactivate, delete, optionally purge the sink)",
		Long: "revoke deactivates then permanently deletes one bedrock.amazonaws.com\n" +
			"credential by ID. With --sink, the secret is deleted from the sink only\n" +
			"after the IAM credential is gone, so no in-flight invocation can succeed\n" +
			"against a sink-only-deleted key. Prompts for confirmation unless --force\n" +
			"is set (use --force in CI / non-interactive scripts).",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()

			cfg, err := loadAWSConfig(ctx, g.Region)
			if err != nil {
				return err
			}

			var s sink.Sink
			var key string
			if sinkURI != "" {
				s, key, err = sink.ParseURI(sinkURI, &cfg)
				if err != nil {
					return err
				}
			}

			return runRevoke(ctx, &revokeDeps{
				iam:  awsapi.NewIAMClient(&cfg),
				sink: s,
				key:  key,
				out:  cmd.OutOrStdout(),
				in:   cmd.InOrStdin(),
			}, revokeRequest{
				user:         user,
				credentialID: credentialID,
				force:        force,
				dryRun:       g.DryRun,
			})
		},
	}

	f := cmd.Flags()
	f.StringVar(&user, "user", "", "IAM user the credential belongs to (required)")
	f.StringVar(&credentialID, "credential-id", "", "ID of the credential to revoke (required)")
	f.StringVar(&sinkURI, "sink", "", "secret sink URI to purge after IAM deletion, e.g. sm://<secret-name> (optional)")
	f.BoolVar(&force, "force", false, "skip the confirmation prompt (for CI / non-interactive use)")
	cobra.CheckErr(cmd.MarkFlagRequired("user"))
	cobra.CheckErr(cmd.MarkFlagRequired("credential-id"))

	return cmd
}

// runRevoke deactivates then deletes the credential, and finally purges
// the sink when one is configured. The IAM-before-sink order ensures a
// revoked credential can never linger valid for an in-flight request.
func runRevoke(ctx context.Context, d *revokeDeps, r revokeRequest) error {
	if r.dryRun {
		msg := fmt.Sprintf("[dry-run] would revoke credential %s for user %q: deactivate, delete",
			r.credentialID, r.user)
		if d.sink != nil {
			msg += ", then delete the secret from the sink"
		}
		_, err := fmt.Fprintln(d.out, msg)
		return err
	}

	if !r.force {
		ok, err := confirm(d.in, d.out,
			fmt.Sprintf("Permanently revoke credential %s for user %s? [y/N]: ", r.credentialID, r.user))
		if err != nil {
			return err
		}
		if !ok {
			warnf(d.out, "revoke aborted\n")
			return nil
		}
	}

	if err := d.iam.SetCredentialStatus(ctx, r.user, r.credentialID, awsapi.StatusInactive); err != nil {
		return fmt.Errorf("deactivate credential: %w", err)
	}
	warnf(d.out, "deactivated credential %s\n", r.credentialID)

	if err := d.iam.DeleteCredential(ctx, r.user, r.credentialID); err != nil {
		return fmt.Errorf("delete credential: %w", err)
	}
	warnf(d.out, "deleted credential %s\n", r.credentialID)

	if d.sink != nil {
		if err := d.sink.Delete(ctx, d.key); err != nil {
			return fmt.Errorf("delete secret from sink: %w", err)
		}
		warnf(d.out, "deleted secret %q from sink\n", d.key)
	}

	return nil
}

// confirm prints prompt and reads a yes/no answer from in. Anything
// other than y/yes (case-insensitive) is treated as no. EOF (e.g. a
// closed stdin in a non-interactive run without --force) counts as no.
func confirm(in io.Reader, out io.Writer, prompt string) (bool, error) {
	warnf(out, "%s", prompt)

	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false, fmt.Errorf("read confirmation: %w", err)
	}

	switch strings.TrimSpace(strings.ToLower(line)) {
	case "y", "yes":
		return true, nil
	default:
		return false, nil
	}
}
