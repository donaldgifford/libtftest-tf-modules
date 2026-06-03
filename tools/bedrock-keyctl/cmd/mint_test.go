package cmd

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/sink"
)

// secretSentinel is a recognisable secret used to assert it never lands
// in human-facing output.
const secretSentinel = "BEARER-TOKEN-NEVER-LOG-abcdef0123456789"

func TestRunMint_Happy(t *testing.T) {
	t.Parallel()

	iam := awsapi.NewMockIAMClient()
	iam.NextSecret = secretSentinel
	snk := sink.NewMockSink()
	var out bytes.Buffer

	err := runMint(context.Background(),
		mintDeps{iam: iam, sink: snk, out: &out},
		mintRequest{user: "platform", key: "k", expiryDays: 90})
	if err != nil {
		t.Fatalf("runMint: %v", err)
	}

	if got := strings.Join(iam.Calls, ","); got != "Create:platform" {
		t.Errorf("IAM calls = %q, want just Create:platform", got)
	}
	if _, ok := snk.Store["k"]; !ok {
		t.Error("nothing written to the sink")
	}
	if strings.Contains(out.String(), secretSentinel) {
		t.Errorf("mint output leaked the secret:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "minted credential") {
		t.Errorf("output missing confirmation line:\n%s", out.String())
	}
	// The sink envelope SHOULD contain the secret (that's its job).
	if !strings.Contains(string(snk.Store["k"]), secretSentinel) {
		t.Error("sink envelope should carry the secret")
	}
}

func TestRunMint_DryRun(t *testing.T) {
	t.Parallel()

	iam := awsapi.NewMockIAMClient()
	snk := sink.NewMockSink()
	var out bytes.Buffer

	err := runMint(context.Background(),
		mintDeps{iam: iam, sink: snk, out: &out},
		mintRequest{user: "platform", key: "k", expiryDays: 90, dryRun: true})
	if err != nil {
		t.Fatalf("runMint dry-run: %v", err)
	}
	if len(iam.Calls) != 0 {
		t.Errorf("dry-run made IAM calls: %v", iam.Calls)
	}
	if len(snk.Calls) != 0 {
		t.Errorf("dry-run made sink calls: %v", snk.Calls)
	}
	if !strings.Contains(out.String(), "[dry-run]") {
		t.Errorf("dry-run output missing marker:\n%s", out.String())
	}
}

func TestRunMint_Errors(t *testing.T) {
	t.Parallel()

	t.Run("create error", func(t *testing.T) {
		t.Parallel()
		iam := awsapi.NewMockIAMClient()
		iam.CreateErr = errors.New("denied")
		err := runMint(context.Background(),
			mintDeps{iam: iam, sink: sink.NewMockSink(), out: &bytes.Buffer{}},
			mintRequest{user: "u", key: "k"})
		if err == nil {
			t.Fatal("want error from create")
		}
	})

	t.Run("sink write error", func(t *testing.T) {
		t.Parallel()
		snk := sink.NewMockSink()
		snk.WriteErr = errors.New("sink down")
		err := runMint(context.Background(),
			mintDeps{iam: awsapi.NewMockIAMClient(), sink: snk, out: &bytes.Buffer{}},
			mintRequest{user: "u", key: "k"})
		if err == nil {
			t.Fatal("want error from sink write")
		}
	})
}

func TestFormatExpiry(t *testing.T) {
	t.Parallel()

	if got := formatExpiry(time.Time{}); got != "no expiry set" {
		t.Errorf("zero expiry = %q, want 'no expiry set'", got)
	}
	expires := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	if got := formatExpiry(expires); !strings.HasPrefix(got, "expires ") {
		t.Errorf("expiry = %q, want 'expires ...'", got)
	}
}
