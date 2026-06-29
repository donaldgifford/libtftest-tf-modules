package cmd

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/enablement"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/targeting"
)

// execRoot runs the root command with args and returns combined output.
func execRoot(t *testing.T, args ...string) (string, error) {
	t.Helper()

	root := newRootCmd()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetErr(&buf)
	root.SetArgs(args)
	err := root.ExecuteContext(context.Background())
	return buf.String(), err
}

// The --dry-run paths exercise each subcommand's RunE wiring (flag
// parsing, loadAWSConfig, sink URI parsing) end-to-end while returning
// before any AWS mutation.
func TestExec_DryRun(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		args []string
	}{
		{"mint", []string{"mint", "--user", "u", "--sink", "sm://x", "--dry-run", "--region", "us-west-2"}},
		{"rotate", []string{"rotate", "--user", "u", "--sink", "sm://x", "--dry-run", "--region", "us-west-2"}},
		{"revoke", []string{"revoke", "--user", "u", "--credential-id", "AKIA1", "--sink", "sm://x", "--dry-run", "--region", "us-west-2"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			out, err := execRoot(t, tc.args...)
			if err != nil {
				t.Fatalf("%s --dry-run: %v\n%s", tc.name, err, out)
			}
			if !strings.Contains(out, "[dry-run]") {
				t.Errorf("%s missing dry-run marker:\n%s", tc.name, out)
			}
		})
	}
}

func TestExec_InvalidFlags(t *testing.T) {
	t.Parallel()

	t.Run("bad log level", func(t *testing.T) {
		t.Parallel()
		if _, err := execRoot(t, "mint", "--user", "u", "--sink", "sm://x", "--log-level", "loud"); err == nil {
			t.Error("want error for invalid --log-level")
		}
	})

	t.Run("missing required flag", func(t *testing.T) {
		t.Parallel()
		if _, err := execRoot(t, "mint", "--sink", "sm://x"); err == nil {
			t.Error("want error when --user is missing")
		}
	})

	t.Run("invalid subscribe path", func(t *testing.T) {
		t.Parallel()
		_, err := execRoot(t, "enable-models", "--models", "amazon.nova", "--marketplace-subscribe-path", "bogus")
		if err == nil {
			t.Error("want error for invalid --marketplace-subscribe-path")
		}
	})

	t.Run("bad models flag", func(t *testing.T) {
		t.Parallel()
		if _, err := execRoot(t, "enable-models", "--models", "noprovider"); err == nil {
			t.Error("want error for dotless model")
		}
	})
}

func TestDispatchTargets_NoModelsIsOffline(t *testing.T) {
	t.Parallel()

	// One ambient target with no models: builds clients but makes no API
	// calls, so it runs fully offline and prints the account header.
	var out bytes.Buffer
	cfg := aws.Config{Region: "us-west-2"}
	targets := []targeting.Target{{AccountID: "111122223333"}}

	err := dispatchTargets(context.Background(), &cfg, &out, targets, nil, enablement.SubscribeAuto)
	if err != nil {
		t.Fatalf("dispatchTargets: %v", err)
	}
	if !strings.Contains(out.String(), "111122223333") {
		t.Errorf("missing account header:\n%s", out.String())
	}
}

func TestLoadAWSConfig(t *testing.T) {
	t.Parallel()

	cfg, err := loadAWSConfig(context.Background(), "eu-central-1")
	if err != nil {
		t.Fatalf("loadAWSConfig: %v", err)
	}
	if cfg.Region != "eu-central-1" {
		t.Errorf("region = %q, want eu-central-1", cfg.Region)
	}
}
