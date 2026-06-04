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

// newRotateFixture seeds one active "OLD" credential and wires mocks. The
// first CreateCredential the mock issues is deterministically
// "AKIAMOCK0001", which is the rotated-in credential under test.
func newRotateFixture(t *testing.T, verifyErr error) (*awsapi.MockIAMClient, *sink.MockSink, *bytes.Buffer, rotateDeps, *int) {
	t.Helper()

	iam := awsapi.NewMockIAMClient()
	iam.NextSecret = secretSentinel
	iam.Seed(awsapi.Credential{ID: "OLD", UserName: "platform", Status: awsapi.StatusActive})

	snk := sink.NewMockSink()
	out := &bytes.Buffer{}
	sleeps := 0

	deps := rotateDeps{
		iam:      iam,
		sink:     snk,
		verifier: func(string) awsapi.BedrockClient { return &awsapi.MockBedrockClient{GetInferenceProfileErr: verifyErr} },
		out:      out,
		sleep: func(context.Context, time.Duration) error {
			sleeps++
			return nil
		},
	}
	return iam, snk, out, deps, &sleeps
}

const newCredID = "AKIAMOCK0001"

func TestRunRotate_HappyPath_Sequence(t *testing.T) {
	t.Parallel()

	iam, snk, out, deps, sleeps := newRotateFixture(t, nil)

	err := runRotate(context.Background(), deps, rotateRequest{
		user: "platform", key: "k", verifyProfile: "profile-1",
		expiryDays: 90, gracePeriod: 5 * time.Minute,
	})
	if err != nil {
		t.Fatalf("runRotate: %v", err)
	}

	wantSeq := "List:platform,Create:platform,SetStatus:OLD=Inactive,Delete:OLD"
	if got := strings.Join(iam.Calls, ","); got != wantSeq {
		t.Errorf("IAM sequence = %q,\nwant            %q", got, wantSeq)
	}
	if !iam.Exists(newCredID) || iam.Status(newCredID) != awsapi.StatusActive {
		t.Error("new credential should be live and Active after rotate")
	}
	if iam.Exists("OLD") {
		t.Error("old credential should be deleted after the grace period")
	}
	if _, ok := snk.Store["k"]; !ok {
		t.Error("new secret should be written to the sink")
	}
	if *sleeps != 1 {
		t.Errorf("grace sleeps = %d, want 1", *sleeps)
	}
	if strings.Contains(out.String(), secretSentinel) {
		t.Errorf("rotate output leaked the secret:\n%s", out.String())
	}
}

func TestRunRotate_VerificationFailure_RollsBack(t *testing.T) {
	t.Parallel()

	iam, snk, _, deps, _ := newRotateFixture(t, errors.New("token rejected"))

	err := runRotate(context.Background(), deps, rotateRequest{
		user: "platform", key: "k", verifyProfile: "profile-1",
		expiryDays: 90, gracePeriod: 5 * time.Minute,
	})
	if err == nil {
		t.Fatal("want error when verification fails")
	}

	// New credential minted then rolled back; old never touched.
	wantSeq := "List:platform,Create:platform,Delete:" + newCredID
	if got := strings.Join(iam.Calls, ","); got != wantSeq {
		t.Errorf("IAM sequence = %q,\nwant            %q", got, wantSeq)
	}
	if iam.Exists(newCredID) {
		t.Error("new credential should be deleted on verification failure")
	}
	if iam.Status("OLD") != awsapi.StatusActive {
		t.Error("old credential must remain Active on verification failure")
	}
	if len(snk.Calls) != 0 {
		t.Errorf("sink must be untouched on verify failure, calls=%v", snk.Calls)
	}
}

func TestRunRotate_SkipVerify_GraceZero(t *testing.T) {
	t.Parallel()

	iam, _, out, deps, sleeps := newRotateFixture(t, nil)

	// No verify-profile → verification skipped; grace 0 → no sleep.
	err := runRotate(context.Background(), deps, rotateRequest{
		user: "platform", key: "k", expiryDays: 90, gracePeriod: 0,
	})
	if err != nil {
		t.Fatalf("runRotate: %v", err)
	}
	if *sleeps != 0 {
		t.Errorf("grace-period 0 should not sleep, got %d", *sleeps)
	}
	if !iam.Exists(newCredID) || iam.Exists("OLD") {
		t.Error("old should be deleted and new should remain")
	}
	if !strings.Contains(out.String(), "not verified") {
		t.Errorf("skipping verify should warn:\n%s", out.String())
	}
}

func TestRunRotate_DryRun(t *testing.T) {
	t.Parallel()

	iam, _, out, deps, _ := newRotateFixture(t, nil)

	err := runRotate(context.Background(), deps, rotateRequest{
		user: "platform", key: "k", dryRun: true,
	})
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

func TestSleepWithContext_Cancel(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := sleepWithContext(ctx, time.Hour); !errors.Is(err, context.Canceled) {
		t.Errorf("sleepWithContext = %v, want context.Canceled", err)
	}

	if err := sleepWithContext(context.Background(), time.Millisecond); err != nil {
		t.Errorf("sleepWithContext short wait = %v, want nil", err)
	}
}
