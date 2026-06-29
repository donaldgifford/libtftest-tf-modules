package cmd

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/sink"
)

func seededIAM() *awsapi.MockIAMClient {
	iam := awsapi.NewMockIAMClient()
	iam.Seed(awsapi.Credential{ID: "CID", UserName: "u", Status: awsapi.StatusActive})
	return iam
}

func TestRunRevoke_ThreeStep_IAMBeforeSink(t *testing.T) {
	t.Parallel()

	iam := seededIAM()
	snk := sink.NewMockSink()
	snk.Store["k"] = []byte("envelope")
	var out bytes.Buffer

	err := runRevoke(context.Background(),
		&revokeDeps{iam: iam, sink: snk, key: "k", out: &out, in: strings.NewReader("")},
		revokeRequest{user: "u", credentialID: "CID", force: true})
	if err != nil {
		t.Fatalf("runRevoke: %v", err)
	}

	if got := strings.Join(iam.Calls, ","); got != "SetStatus:CID=Inactive,Delete:CID" {
		t.Errorf("IAM calls = %q, want SetStatus then Delete", got)
	}
	if got := strings.Join(snk.Calls, ","); got != "Delete:k" {
		t.Errorf("sink calls = %q, want Delete:k", got)
	}
	if iam.Exists("CID") {
		t.Error("credential should be deleted")
	}
	if _, ok := snk.Store["k"]; ok {
		t.Error("secret should be purged from the sink")
	}
}

func TestRunRevoke_TwoStep_NoSink(t *testing.T) {
	t.Parallel()

	iam := seededIAM()
	var out bytes.Buffer

	err := runRevoke(context.Background(),
		&revokeDeps{iam: iam, sink: nil, out: &out, in: strings.NewReader("")},
		revokeRequest{user: "u", credentialID: "CID", force: true})
	if err != nil {
		t.Fatalf("runRevoke: %v", err)
	}
	if got := strings.Join(iam.Calls, ","); got != "SetStatus:CID=Inactive,Delete:CID" {
		t.Errorf("IAM calls = %q", got)
	}
}

func TestRunRevoke_ConfirmAndAbort(t *testing.T) {
	t.Parallel()

	t.Run("yes proceeds", func(t *testing.T) {
		t.Parallel()
		iam := seededIAM()
		err := runRevoke(context.Background(),
			&revokeDeps{iam: iam, out: &bytes.Buffer{}, in: strings.NewReader("y\n")},
			revokeRequest{user: "u", credentialID: "CID"})
		if err != nil {
			t.Fatalf("runRevoke: %v", err)
		}
		if len(iam.Calls) != 2 {
			t.Errorf("expected revoke to proceed, calls=%v", iam.Calls)
		}
	})

	t.Run("no aborts", func(t *testing.T) {
		t.Parallel()
		iam := seededIAM()
		var out bytes.Buffer
		err := runRevoke(context.Background(),
			&revokeDeps{iam: iam, out: &out, in: strings.NewReader("n\n")},
			revokeRequest{user: "u", credentialID: "CID"})
		if err != nil {
			t.Fatalf("abort should not error: %v", err)
		}
		if len(iam.Calls) != 0 {
			t.Errorf("abort should make no IAM calls, got %v", iam.Calls)
		}
		if !strings.Contains(out.String(), "aborted") {
			t.Errorf("missing abort message:\n%s", out.String())
		}
	})
}

func TestRunRevoke_Errors(t *testing.T) {
	t.Parallel()

	t.Run("deactivate error", func(t *testing.T) {
		t.Parallel()
		iam := seededIAM()
		iam.SetStatusErr = errors.New("denied")
		err := runRevoke(context.Background(),
			&revokeDeps{iam: iam, out: &bytes.Buffer{}, in: strings.NewReader("")},
			revokeRequest{user: "u", credentialID: "CID", force: true})
		if err == nil {
			t.Fatal("want error from deactivate")
		}
	})

	t.Run("delete error", func(t *testing.T) {
		t.Parallel()
		iam := seededIAM()
		iam.DeleteErr = errors.New("denied")
		err := runRevoke(context.Background(),
			&revokeDeps{iam: iam, out: &bytes.Buffer{}, in: strings.NewReader("")},
			revokeRequest{user: "u", credentialID: "CID", force: true})
		if err == nil {
			t.Fatal("want error from delete")
		}
	})
}

func TestRunRevoke_DryRun(t *testing.T) {
	t.Parallel()

	iam := seededIAM()
	var out bytes.Buffer
	err := runRevoke(context.Background(),
		&revokeDeps{iam: iam, sink: sink.NewMockSink(), key: "k", out: &out, in: strings.NewReader("")},
		revokeRequest{user: "u", credentialID: "CID", dryRun: true})
	if err != nil {
		t.Fatalf("dry-run: %v", err)
	}
	if len(iam.Calls) != 0 {
		t.Errorf("dry-run made IAM calls: %v", iam.Calls)
	}
	if !strings.Contains(out.String(), "[dry-run]") {
		t.Errorf("missing dry-run marker:\n%s", out.String())
	}
}

func TestConfirm_EOFIsNo(t *testing.T) {
	t.Parallel()

	ok, err := confirm(strings.NewReader(""), &bytes.Buffer{}, "go? ")
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if ok {
		t.Error("EOF (closed stdin) should be treated as no")
	}
}
