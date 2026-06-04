package awsapi

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/credential"
)

func TestConstructors_BuildNonNil(t *testing.T) {
	t.Parallel()

	cfg := &aws.Config{Region: "us-west-2"}
	if NewIAMClient(cfg) == nil {
		t.Error("NewIAMClient returned nil")
	}
	if NewBedrockClient(cfg) == nil {
		t.Error("NewBedrockClient returned nil")
	}
	if NewBedrockClientWithToken("us-west-2", "tok") == nil {
		t.Error("NewBedrockClientWithToken returned nil")
	}
	if NewSTSClient(cfg) == nil {
		t.Error("NewSTSClient returned nil")
	}
	if NewMarketplaceClient(cfg) == nil {
		t.Error("NewMarketplaceClient returned nil")
	}
}

func TestMarketplaceClient_V1Behaviour(t *testing.T) {
	t.Parallel()

	c := NewMarketplaceClient(&aws.Config{})
	ctx := context.Background()

	subscribed, err := c.IsSubscribed(ctx, "meta.llama")
	if err != nil || subscribed {
		t.Errorf("IsSubscribed = (%v, %v), want (false, nil)", subscribed, err)
	}
	if err := c.Subscribe(ctx, "meta.llama"); !errors.Is(err, ErrSubscribeUnsupported) {
		t.Errorf("Subscribe err = %v, want ErrSubscribeUnsupported", err)
	}
}

func TestMockIAMClient_LifecycleAndSequence(t *testing.T) {
	t.Parallel()

	m := NewMockIAMClient()
	m.NextSecret = "s3cr3t"
	ctx := context.Background()

	m.Seed(Credential{ID: "OLD1", UserName: "u", Status: StatusActive})

	created, err := m.CreateCredential(ctx, "u", 90)
	if err != nil {
		t.Fatalf("CreateCredential: %v", err)
	}
	if created.Secret.Reveal(credential.SinkToken) != "s3cr3t" {
		t.Error("created secret not threaded from NextSecret")
	}
	if m.Status(created.ID) != StatusActive {
		t.Errorf("new cred status = %q, want Active", m.Status(created.ID))
	}

	creds, err := m.ListCredentials(ctx, "u")
	if err != nil {
		t.Fatalf("ListCredentials: %v", err)
	}
	if len(creds) != 2 {
		t.Errorf("listed %d creds, want 2 (seeded old + new)", len(creds))
	}

	if err := m.SetCredentialStatus(ctx, "u", "OLD1", StatusInactive); err != nil {
		t.Fatalf("SetCredentialStatus: %v", err)
	}
	if m.Status("OLD1") != StatusInactive {
		t.Errorf("OLD1 status = %q, want Inactive", m.Status("OLD1"))
	}

	if err := m.DeleteCredential(ctx, "u", "OLD1"); err != nil {
		t.Fatalf("DeleteCredential: %v", err)
	}
	if m.Exists("OLD1") {
		t.Error("OLD1 still present after delete")
	}

	wantCalls := []string{"Create:u", "List:u", "SetStatus:OLD1=Inactive", "Delete:OLD1"}
	if got := joinCalls(m.Calls); got != joinCalls(wantCalls) {
		t.Errorf("call sequence = %v, want %v", m.Calls, wantCalls)
	}
}

func TestMockIAMClient_ErrorInjection(t *testing.T) {
	t.Parallel()

	sentinel := errors.New("boom")
	ctx := context.Background()

	m := NewMockIAMClient()
	m.CreateErr = sentinel
	if _, err := m.CreateCredential(ctx, "u", 0); !errors.Is(err, sentinel) {
		t.Errorf("CreateCredential err = %v, want sentinel", err)
	}

	m = NewMockIAMClient()
	m.ListErr = sentinel
	if _, err := m.ListCredentials(ctx, "u"); !errors.Is(err, sentinel) {
		t.Errorf("ListCredentials err = %v, want sentinel", err)
	}

	m = NewMockIAMClient()
	m.SetStatusErr = sentinel
	if err := m.SetCredentialStatus(ctx, "u", "X", StatusInactive); !errors.Is(err, sentinel) {
		t.Errorf("SetCredentialStatus err = %v, want sentinel", err)
	}

	m = NewMockIAMClient()
	m.DeleteErr = sentinel
	if err := m.DeleteCredential(ctx, "u", "X"); !errors.Is(err, sentinel) {
		t.Errorf("DeleteCredential err = %v, want sentinel", err)
	}
}

func TestMockBedrockAndMarketplaceAndSTS(t *testing.T) {
	t.Parallel()

	ctx := context.Background()

	bc := &MockBedrockClient{}
	_ = bc.GetInferenceProfile(ctx, "p")
	_ = bc.PutUseCaseForModelAccess(ctx, []byte("{}"))
	_ = bc.InvokeModel(ctx, "m", []byte("{}"))
	if bc.GetInferenceProfileCount != 1 || bc.PutUseCaseCount != 1 || bc.InvokeCount != 1 {
		t.Errorf("bedrock counts = %d/%d/%d, want 1/1/1",
			bc.GetInferenceProfileCount, bc.PutUseCaseCount, bc.InvokeCount)
	}

	mkt := &MockMarketplaceClient{Subscribed: true}
	if ok, _ := mkt.IsSubscribed(ctx, "m"); !ok {
		t.Error("MockMarketplaceClient.IsSubscribed should report configured Subscribed")
	}
	_ = mkt.Subscribe(ctx, "m")
	if mkt.SubscribeCount != 1 {
		t.Errorf("SubscribeCount = %d, want 1", mkt.SubscribeCount)
	}

	sts := &MockSTSClient{Account: "111122223333", Creds: AssumedCredentials{AccessKeyID: "AK"}}
	if acct, _ := sts.CallerAccountID(ctx); acct != "111122223333" {
		t.Errorf("CallerAccountID = %q", acct)
	}
	creds, _ := sts.AssumeRole(ctx, "arn:aws:iam::111122223333:role/r", "sess")
	if creds.AccessKeyID != "AK" || len(sts.AssumeRoleARNs) != 1 {
		t.Errorf("AssumeRole returned %+v, calls=%v", creds, sts.AssumeRoleARNs)
	}
}

func joinCalls(calls []string) string {
	out := ""
	for _, c := range calls {
		out += c + ";"
	}
	return out
}
