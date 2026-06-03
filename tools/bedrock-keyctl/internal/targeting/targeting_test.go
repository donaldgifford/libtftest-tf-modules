package targeting

import (
	"context"
	"errors"
	"testing"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
)

func TestResolveTargets_Current(t *testing.T) {
	t.Parallel()

	sts := &awsapi.MockSTSClient{Account: "111122223333"}
	targets, err := ResolveTargets(context.Background(), sts, ModeCurrent, "bedrock-enablement", "sess")
	if err != nil {
		t.Fatalf("ResolveTargets: %v", err)
	}

	if len(targets) != 1 {
		t.Fatalf("got %d targets, want 1", len(targets))
	}
	if targets[0].AccountID != "111122223333" {
		t.Errorf("AccountID = %q, want the caller account", targets[0].AccountID)
	}
	if targets[0].Credentials != nil {
		t.Error("current target should use ambient credentials (nil)")
	}
	if targets[0].CascadeOnlyAnthropic {
		t.Error("current target should not be cascade-only")
	}
	if len(sts.AssumeRoleARNs) != 0 {
		t.Errorf("current mode made %d AssumeRole calls, want 0", len(sts.AssumeRoleARNs))
	}
}

func TestResolveTargets_OrgManagement(t *testing.T) {
	t.Parallel()

	sts := &awsapi.MockSTSClient{Account: "111122223333"}
	targets, err := ResolveTargets(context.Background(), sts, ModeOrgManagement, "bedrock-enablement", "sess")
	if err != nil {
		t.Fatalf("ResolveTargets: %v", err)
	}

	if len(targets) != 1 || !targets[0].CascadeOnlyAnthropic {
		t.Fatalf("org-management target = %+v, want one cascade-only target", targets)
	}
	if len(sts.AssumeRoleARNs) != 0 {
		t.Errorf("org-management mode made %d AssumeRole calls, want 0", len(sts.AssumeRoleARNs))
	}
}

func TestResolveTargets_AccountList(t *testing.T) {
	t.Parallel()

	sts := &awsapi.MockSTSClient{
		Account: "999988887777",
		Creds:   awsapi.AssumedCredentials{AccessKeyID: "AK", SecretAccessKey: "SK", SessionToken: "ST"},
	}
	targets, err := ResolveTargets(
		context.Background(), sts, "111122223333, 444455556666", "bedrock-enablement", "sess")
	if err != nil {
		t.Fatalf("ResolveTargets: %v", err)
	}

	if len(targets) != 2 {
		t.Fatalf("got %d targets, want 2", len(targets))
	}
	wantARNs := []string{
		"arn:aws:iam::111122223333:role/bedrock-enablement",
		"arn:aws:iam::444455556666:role/bedrock-enablement",
	}
	for i, want := range wantARNs {
		if sts.AssumeRoleARNs[i] != want {
			t.Errorf("AssumeRole[%d] = %q, want %q", i, sts.AssumeRoleARNs[i], want)
		}
	}
	for i := range targets {
		if targets[i].Credentials == nil || targets[i].Credentials.AccessKeyID != "AK" {
			t.Errorf("target[%d] missing assumed credentials", i)
		}
		if targets[i].CascadeOnlyAnthropic {
			t.Errorf("target[%d] should not be cascade-only", i)
		}
	}
}

func TestResolveTargets_Errors(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	boom := errors.New("boom")

	t.Run("caller error in current", func(t *testing.T) {
		t.Parallel()
		sts := &awsapi.MockSTSClient{CallerErr: boom}
		if _, err := ResolveTargets(ctx, sts, ModeCurrent, "r", "s"); !errors.Is(err, boom) {
			t.Errorf("err = %v, want boom", err)
		}
	})

	t.Run("assume-role error in list", func(t *testing.T) {
		t.Parallel()
		sts := &awsapi.MockSTSClient{AssumeErr: boom}
		if _, err := ResolveTargets(ctx, sts, "111122223333", "r", "s"); !errors.Is(err, boom) {
			t.Errorf("err = %v, want boom", err)
		}
	})

	t.Run("invalid account id rejected", func(t *testing.T) {
		t.Parallel()
		sts := &awsapi.MockSTSClient{}
		if _, err := ResolveTargets(ctx, sts, "not-an-account", "r", "s"); err == nil {
			t.Error("want error for non-account-id mode")
		}
		if len(sts.AssumeRoleARNs) != 0 {
			t.Error("invalid id should not trigger AssumeRole")
		}
	})

	t.Run("short numeric id rejected", func(t *testing.T) {
		t.Parallel()
		sts := &awsapi.MockSTSClient{}
		if _, err := ResolveTargets(ctx, sts, "12345", "r", "s"); err == nil {
			t.Error("want error for too-short account id")
		}
	})

	t.Run("empty list rejected", func(t *testing.T) {
		t.Parallel()
		sts := &awsapi.MockSTSClient{}
		if _, err := ResolveTargets(ctx, sts, ",,", "r", "s"); err == nil {
			t.Error("want error for empty account list")
		}
	})
}
