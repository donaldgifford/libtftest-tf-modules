package cmd

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"os"

	"github.com/aws/aws-sdk-go-v2/aws"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/sink"
)

func TestGlobalOptions_Validate(t *testing.T) {
	t.Parallel()

	for _, lvl := range []string{"debug", "info", "warn", "error"} {
		if err := (&GlobalOptions{LogLevel: lvl}).validate(); err != nil {
			t.Errorf("validate(%q) = %v, want nil", lvl, err)
		}
	}
	if err := (&GlobalOptions{LogLevel: "loud"}).validate(); err == nil {
		t.Error("validate(loud) = nil, want error")
	}
}

func TestNewRootCmd_WiresSubcommands(t *testing.T) {
	t.Parallel()

	root := newRootCmd()
	want := map[string]bool{"mint": false, "rotate": false, "revoke": false, "enable-models": false}
	for _, c := range root.Commands() {
		want[c.Name()] = true
	}
	for name, found := range want {
		if !found {
			t.Errorf("root command missing subcommand %q", name)
		}
	}
}

func TestParseModelsFlag(t *testing.T) {
	t.Parallel()

	t.Run("csv", func(t *testing.T) {
		t.Parallel()
		specs, err := parseModelsFlag("anthropic.claude,meta.llama")
		if err != nil {
			t.Fatalf("parseModelsFlag: %v", err)
		}
		if len(specs) != 2 {
			t.Errorf("got %d specs, want 2", len(specs))
		}
	})

	t.Run("json file", func(t *testing.T) {
		t.Parallel()
		dir := t.TempDir()
		path := filepath.Join(dir, "models.json")
		body := `[{"provider":"anthropic","model_id":"anthropic.claude"}]`
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		specs, err := parseModelsFlag("@" + path)
		if err != nil {
			t.Fatalf("parseModelsFlag(@file): %v", err)
		}
		if len(specs) != 1 || specs[0].Provider != "anthropic" {
			t.Errorf("got %+v, want one anthropic spec", specs)
		}
	})

	t.Run("missing file errors", func(t *testing.T) {
		t.Parallel()
		if _, err := parseModelsFlag("@/no/such/file.json"); err == nil {
			t.Error("want error for missing file")
		}
	})

	t.Run("bad csv errors", func(t *testing.T) {
		t.Parallel()
		if _, err := parseModelsFlag("noprovider"); err == nil {
			t.Error("want error for dotless model")
		}
	})
}

func TestConfigForCredentials(t *testing.T) {
	t.Parallel()

	base := aws.Config{Region: "us-west-2"}
	cfg := configForCredentials(&base, awsapi.AssumedCredentials{
		AccessKeyID: "AK", SecretAccessKey: "SK", SessionToken: "ST",
	})

	if cfg.Region != "us-west-2" {
		t.Errorf("region not preserved: %q", cfg.Region)
	}
	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Retrieve: %v", err)
	}
	if creds.AccessKeyID != "AK" || creds.SecretAccessKey != "SK" || creds.SessionToken != "ST" {
		t.Errorf("static creds not applied: %+v", creds)
	}
}

// TestSecretNeverLogged is the cross-cutting invariant test: a mint
// followed by a rotate must never emit the raw secret to the human-facing
// output stream, only to the sink envelope.
func TestSecretNeverLogged(t *testing.T) {
	t.Parallel()

	var out bytes.Buffer
	ctx := context.Background()

	iam := awsapi.NewMockIAMClient()
	iam.NextSecret = secretSentinel
	snk := sink.NewMockSink()

	if err := runMint(ctx, mintDeps{iam: iam, sink: snk, out: &out},
		mintRequest{user: "platform", key: "k", expiryDays: 90}); err != nil {
		t.Fatalf("mint: %v", err)
	}

	iam2 := awsapi.NewMockIAMClient()
	iam2.NextSecret = secretSentinel
	iam2.Seed(awsapi.Credential{ID: "OLD", UserName: "platform", Status: awsapi.StatusActive})
	deps := rotateDeps{
		iam:      iam2,
		sink:     snk,
		verifier: func(string) awsapi.BedrockClient { return &awsapi.MockBedrockClient{} },
		out:      &out,
		sleep:    func(context.Context, time.Duration) error { return nil },
	}
	if err := runRotate(ctx, deps, rotateRequest{
		user: "platform", key: "k", verifyProfile: "p", expiryDays: 90,
	}); err != nil {
		t.Fatalf("rotate: %v", err)
	}

	if strings.Contains(out.String(), secretSentinel) {
		t.Fatalf("secret leaked to output stream:\n%s", out.String())
	}
	// Sanity: the secret really did flow (into the sink), so the test is
	// meaningful and not passing because the secret was empty.
	if !strings.Contains(string(snk.Store["k"]), secretSentinel) {
		t.Error("secret never reached the sink — test would be vacuous")
	}
}
