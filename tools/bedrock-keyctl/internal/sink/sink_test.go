package sink

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	smtypes "github.com/aws/aws-sdk-go-v2/service/secretsmanager/types"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/credential"
)

// fakeSMAPI is an in-memory secretsManagerAPI for testing the sink's
// create-then-put logic without the AWS SDK.
type fakeSMAPI struct {
	store       map[string]string
	createCalls int
	putCalls    int
	getCalls    int
	deleteCalls int
	createErr   error
	getErr      error
}

func newFakeSMAPI() *fakeSMAPI {
	return &fakeSMAPI{store: make(map[string]string)}
}

func (f *fakeSMAPI) CreateSecret(_ context.Context, in *secretsmanager.CreateSecretInput, _ ...func(*secretsmanager.Options)) (*secretsmanager.CreateSecretOutput, error) {
	f.createCalls++
	if f.createErr != nil {
		return nil, f.createErr
	}
	name := aws.ToString(in.Name)
	if _, ok := f.store[name]; ok {
		return nil, &smtypes.ResourceExistsException{Message: aws.String("already exists")}
	}
	f.store[name] = aws.ToString(in.SecretString)
	return &secretsmanager.CreateSecretOutput{ARN: aws.String("arn:aws:secretsmanager:::secret:" + name)}, nil
}

func (f *fakeSMAPI) PutSecretValue(_ context.Context, in *secretsmanager.PutSecretValueInput, _ ...func(*secretsmanager.Options)) (*secretsmanager.PutSecretValueOutput, error) {
	f.putCalls++
	f.store[aws.ToString(in.SecretId)] = aws.ToString(in.SecretString)
	return &secretsmanager.PutSecretValueOutput{}, nil
}

func (f *fakeSMAPI) GetSecretValue(_ context.Context, in *secretsmanager.GetSecretValueInput, _ ...func(*secretsmanager.Options)) (*secretsmanager.GetSecretValueOutput, error) {
	f.getCalls++
	if f.getErr != nil {
		return nil, f.getErr
	}
	v, ok := f.store[aws.ToString(in.SecretId)]
	if !ok {
		return nil, &smtypes.ResourceNotFoundException{Message: aws.String("not found")}
	}
	return &secretsmanager.GetSecretValueOutput{SecretString: aws.String(v)}, nil
}

func (f *fakeSMAPI) DeleteSecret(_ context.Context, in *secretsmanager.DeleteSecretInput, _ ...func(*secretsmanager.Options)) (*secretsmanager.DeleteSecretOutput, error) {
	f.deleteCalls++
	delete(f.store, aws.ToString(in.SecretId))
	return &secretsmanager.DeleteSecretOutput{}, nil
}

func TestSecretsManagerSink_WriteCreatesThenPuts(t *testing.T) {
	t.Parallel()

	fake := newFakeSMAPI()
	s := &SecretsManagerSink{api: fake}
	ctx := context.Background()

	if err := s.Write(ctx, "k", []byte("v1")); err != nil {
		t.Fatalf("first Write: %v", err)
	}
	if fake.createCalls != 1 || fake.putCalls != 0 {
		t.Fatalf("first write: createCalls=%d putCalls=%d, want 1/0", fake.createCalls, fake.putCalls)
	}

	if err := s.Write(ctx, "k", []byte("v2")); err != nil {
		t.Fatalf("second Write: %v", err)
	}
	if fake.createCalls != 2 || fake.putCalls != 1 {
		t.Fatalf("second write: createCalls=%d putCalls=%d, want 2/1 (create attempted then put fallback)", fake.createCalls, fake.putCalls)
	}
	if got := fake.store["k"]; got != "v2" {
		t.Errorf("stored value = %q, want v2 (latest)", got)
	}
}

func TestSecretsManagerSink_RoundTrip(t *testing.T) {
	t.Parallel()

	fake := newFakeSMAPI()
	s := &SecretsManagerSink{api: fake}
	ctx := context.Background()

	if err := s.Write(ctx, "k", []byte("payload")); err != nil {
		t.Fatalf("Write: %v", err)
	}

	got, err := s.Read(ctx, "k")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if string(got) != "payload" {
		t.Errorf("Read = %q, want payload", got)
	}

	if err := s.Delete(ctx, "k"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok := fake.store["k"]; ok {
		t.Errorf("key still present after Delete")
	}
}

func TestSecretsManagerSink_CreateErrorPropagates(t *testing.T) {
	t.Parallel()

	sentinel := errors.New("boom")
	fake := newFakeSMAPI()
	fake.createErr = sentinel
	s := &SecretsManagerSink{api: fake}

	err := s.Write(context.Background(), "k", []byte("v"))
	if !errors.Is(err, sentinel) {
		t.Errorf("Write error = %v, want wrapped %v", err, sentinel)
	}
	if fake.putCalls != 0 {
		t.Errorf("putCalls = %d, want 0 (non-exists error must not fall through to put)", fake.putCalls)
	}
}

func TestWriteReadCredential_RoundTrip(t *testing.T) {
	t.Parallel()

	fake := newFakeSMAPI()
	s := &SecretsManagerSink{api: fake}
	ctx := context.Background()

	expires := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	secret := credential.NewSecretValue("bedrock-bearer-token-value")

	if err := WriteCredential(ctx, s, "k", "CRED123", secret, expires); err != nil {
		t.Fatalf("WriteCredential: %v", err)
	}

	env, err := ReadCredential(ctx, s, "k")
	if err != nil {
		t.Fatalf("ReadCredential: %v", err)
	}
	if env.BedrockAPIKey != "bedrock-bearer-token-value" {
		t.Errorf("BedrockAPIKey = %q, want the revealed token", env.BedrockAPIKey)
	}
	if env.CredentialID != "CRED123" {
		t.Errorf("CredentialID = %q, want CRED123", env.CredentialID)
	}
	if !env.ExpiresAt.Equal(expires) {
		t.Errorf("ExpiresAt = %v, want %v", env.ExpiresAt, expires)
	}
}
