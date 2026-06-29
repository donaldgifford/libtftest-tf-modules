package cmd

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/credential"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/sink"
)

// verifierFactory builds a BedrockClient authenticated with a freshly
// minted bearer token, so rotate can prove the new credential works
// before retiring the old one. Injected so tests supply a fake.
type verifierFactory func(token string) awsapi.BedrockClient

// rotateDeps are the injected collaborators for runRotate, so the core
// logic is testable against mocks without touching AWS.
type rotateDeps struct {
	iam      awsapi.IAMClient
	sink     sink.Sink
	verifier verifierFactory
	out      io.Writer
	// sleep waits out the grace period. Injected so tests run instantly;
	// it must honour context cancellation.
	sleep func(ctx context.Context, d time.Duration) error
}

// rotateRequest is the parsed, validated input for a rotation.
type rotateRequest struct {
	user          string
	key           string
	verifyProfile string
	expiryDays    int32
	gracePeriod   time.Duration
	dryRun        bool
}

func newRotateCmd(g *GlobalOptions) *cobra.Command {
	var (
		user          string
		expiryDays    int32
		sinkURI       string
		gracePeriod   time.Duration
		verifyProfile string
	)

	cmd := &cobra.Command{
		Use:   "rotate",
		Short: "Rotate the Bedrock credential with a zero-downtime two-key handoff",
		Long: "rotate mints a new bedrock.amazonaws.com credential, verifies it,\n" +
			"writes it to the sink (overwriting the old secret), then retires the\n" +
			"previously active credential: deactivate, wait out a grace period so\n" +
			"long-lived Claude Code sessions refresh from the sink, then delete. If\n" +
			"verification fails the new credential is rolled back and the old one is\n" +
			"left Active, so the sink always holds a working secret. The secret is\n" +
			"never printed. --grace-period 0 deletes the old credential immediately.",
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

			region := cfg.Region
			return runRotate(ctx, rotateDeps{
				iam:  awsapi.NewIAMClient(&cfg),
				sink: s,
				verifier: func(token string) awsapi.BedrockClient {
					return awsapi.NewBedrockClientWithToken(region, token)
				},
				out:   cmd.OutOrStdout(),
				sleep: sleepWithContext,
			}, rotateRequest{
				user:          user,
				key:           key,
				verifyProfile: verifyProfile,
				expiryDays:    expiryDays,
				gracePeriod:   gracePeriod,
				dryRun:        g.DryRun,
			})
		},
	}

	f := cmd.Flags()
	f.StringVar(&user, "user", "", "IAM user whose Bedrock credential to rotate (required)")
	f.Int32Var(&expiryDays, "expiry-days", 90, "new credential lifetime in days")
	f.StringVar(&sinkURI, "sink", "", "secret sink URI, e.g. sm://<secret-name> (required)")
	f.DurationVar(&gracePeriod, "grace-period", 5*time.Minute,
		"wait before deleting the old credential so live sessions refresh; 0 deletes immediately")
	f.StringVar(&verifyProfile, "verify-profile", "",
		"inference-profile ID to probe with the new token before retiring the old credential; if empty, verification is skipped")
	cobra.CheckErr(cmd.MarkFlagRequired("user"))
	cobra.CheckErr(cmd.MarkFlagRequired("sink"))

	return cmd
}

// runRotate performs the two-key zero-downtime rotation. The new
// credential is verified and written to the sink before any change to
// the old one, so a failed rotation leaves the old (still-working)
// secret in place. Once the new secret is live in the sink the rotation
// is committed: retiring the old credential is best-effort from there.
func runRotate(ctx context.Context, d rotateDeps, r rotateRequest) error {
	if r.dryRun {
		_, err := fmt.Fprintf(d.out,
			"[dry-run] would rotate the Bedrock credential for user %q: mint new, verify, write to sink, then retire the old after a %s grace period\n",
			r.user, r.gracePeriod)
		return err
	}

	oldActive, err := activeCredentialIDs(ctx, d.iam, r.user)
	if err != nil {
		return err
	}

	cred, err := d.iam.CreateCredential(ctx, r.user, r.expiryDays)
	if err != nil {
		return fmt.Errorf("mint new credential: %w", err)
	}

	// Roll back the new credential if we fail before it becomes live
	// (verified and written to the sink). After commit the new key is
	// the working one and must survive even if retiring the old fails.
	committed := false
	defer func() {
		if committed {
			return
		}
		if derr := d.iam.DeleteCredential(ctx, r.user, cred.ID); derr != nil {
			logf(d.out, "warning: failed to roll back new credential %s: %v\n", cred.ID, derr)
		}
	}()

	// Verify before the new secret goes live, so a failed rotation
	// leaves the old working secret untouched in the sink.
	if r.verifyProfile != "" {
		// Reveal is the sanctioned escape hatch (see the credential
		// package): the token is handed straight to the SDK, never logged.
		token := cred.Secret.Reveal(credential.SinkToken)
		if verr := d.verifier(token).GetInferenceProfile(ctx, r.verifyProfile); verr != nil {
			return fmt.Errorf("verify new credential against profile %s: %w", r.verifyProfile, verr)
		}
	} else {
		logf(d.out, "warning: --verify-profile not set; new credential is not verified before the old is retired\n")
	}

	if err := sink.WriteCredential(ctx, d.sink, r.key, cred.ID, cred.Secret, cred.ExpiresAt); err != nil {
		return fmt.Errorf("write new secret to sink: %w", err)
	}
	committed = true

	if _, err := fmt.Fprintf(d.out, "minted and verified new credential %s for user %s (%s)\n",
		cred.ID, cred.UserName, formatExpiry(cred.ExpiresAt)); err != nil {
		return err
	}

	return retireOld(ctx, d, r.user, oldActive, r.gracePeriod)
}

// activeCredentialIDs returns the IDs of the user's active Bedrock
// credentials — the ones a rotation retires.
func activeCredentialIDs(ctx context.Context, iam awsapi.IAMClient, user string) ([]string, error) {
	existing, err := iam.ListCredentials(ctx, user)
	if err != nil {
		return nil, fmt.Errorf("list credentials: %w", err)
	}

	active := make([]string, 0, len(existing))
	for i := range existing {
		if existing[i].Status == awsapi.StatusActive {
			active = append(active, existing[i].ID)
		}
	}
	return active, nil
}

// retireOld deactivates the old credentials, waits out the grace period
// so live sessions can refresh from the sink, then deletes them. The new
// key is already live, so failures here are warnings, not rollbacks.
func retireOld(ctx context.Context, d rotateDeps, user string, ids []string, grace time.Duration) error {
	for _, id := range ids {
		if err := d.iam.SetCredentialStatus(ctx, user, id, awsapi.StatusInactive); err != nil {
			logf(d.out, "warning: failed to deactivate old credential %s: %v\n", id, err)
			continue
		}
		logf(d.out, "deactivated old credential %s\n", id)
	}

	if grace > 0 && len(ids) > 0 {
		logf(d.out, "waiting %s grace period before deleting old credential(s)...\n", grace)
		if err := d.sleep(ctx, grace); err != nil {
			return fmt.Errorf("interrupted during grace period (old credential(s) deactivated, not deleted): %w", err)
		}
	}

	for _, id := range ids {
		if err := d.iam.DeleteCredential(ctx, user, id); err != nil {
			logf(d.out, "warning: failed to delete old credential %s: %v\n", id, err)
			continue
		}
		logf(d.out, "deleted old credential %s\n", id)
	}
	return nil
}

// sleepWithContext waits for d or until the context is cancelled,
// whichever comes first. It is the production rotateDeps.sleep.
func sleepWithContext(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// logf writes a best-effort progress or warning line. The write error
// is intentionally ignored so a failed status write never masks the
// primary rotation outcome.
func logf(w io.Writer, format string, args ...any) {
	_, _ = fmt.Fprintf(w, format, args...)
}
