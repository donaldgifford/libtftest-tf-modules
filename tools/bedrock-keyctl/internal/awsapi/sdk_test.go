package awsapi

import (
	"context"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/bedrock"
	"github.com/aws/aws-sdk-go-v2/service/bedrockruntime"
	awsiam "github.com/aws/aws-sdk-go-v2/service/iam"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	ststypes "github.com/aws/aws-sdk-go-v2/service/sts/types"
	"github.com/aws/smithy-go/middleware"
)

// stubResult returns an API option that short-circuits the SDK request
// pipeline in the Finalize step, before signing and the HTTP send, and
// hands back out as the operation result. It lets the SDK-backed client
// methods run end-to-end offline with no canned wire bytes.
func stubResult(out interface{}) func(*middleware.Stack) error {
	return func(stack *middleware.Stack) error {
		return stack.Finalize.Add(
			middleware.FinalizeMiddlewareFunc("stubResult",
				func(context.Context, middleware.FinalizeInput, middleware.FinalizeHandler) (middleware.FinalizeOutput, middleware.Metadata, error) {
					return middleware.FinalizeOutput{Result: out}, middleware.Metadata{}, nil
				}),
			middleware.Before,
		)
	}
}

func stubCfg() aws.Config {
	return aws.Config{Region: "us-west-2"}
}

func TestIAMClient_Methods(t *testing.T) {
	t.Parallel()

	cfg := stubCfg()
	ctx := context.Background()
	now := time.Date(2026, 6, 3, 0, 0, 0, 0, time.UTC)

	create := &iamClient{api: awsiam.NewFromConfig(cfg, withOpt(stubResult(&awsiam.CreateServiceSpecificCredentialOutput{
		ServiceSpecificCredential: &iamtypes.ServiceSpecificCredential{
			ServiceSpecificCredentialId: aws.String("AKIA1"),
			UserName:                    aws.String("u"),
			Status:                      iamtypes.StatusTypeActive,
			ServiceCredentialSecret:     aws.String("token-secret"),
			CreateDate:                  aws.Time(now),
			ExpirationDate:              aws.Time(now.Add(24 * time.Hour)),
		},
	})))}
	got, err := create.CreateCredential(ctx, "u", 90)
	if err != nil {
		t.Fatalf("CreateCredential: %v", err)
	}
	if got.ID != "AKIA1" || got.Secret.IsZero() {
		t.Errorf("CreateCredential got %+v", got)
	}

	list := &iamClient{api: awsiam.NewFromConfig(cfg, withOpt(stubResult(&awsiam.ListServiceSpecificCredentialsOutput{
		ServiceSpecificCredentials: []iamtypes.ServiceSpecificCredentialMetadata{{
			ServiceSpecificCredentialId: aws.String("AKIA1"),
			UserName:                    aws.String("u"),
			Status:                      iamtypes.StatusTypeActive,
		}},
	})))}
	creds, err := list.ListCredentials(ctx, "u")
	if err != nil || len(creds) != 1 {
		t.Fatalf("ListCredentials got %v, err %v", creds, err)
	}

	upd := &iamClient{api: awsiam.NewFromConfig(cfg, withOpt(stubResult(&awsiam.UpdateServiceSpecificCredentialOutput{})))}
	if err := upd.SetCredentialStatus(ctx, "u", "AKIA1", StatusInactive); err != nil {
		t.Fatalf("SetCredentialStatus: %v", err)
	}

	del := &iamClient{api: awsiam.NewFromConfig(cfg, withOpt(stubResult(&awsiam.DeleteServiceSpecificCredentialOutput{})))}
	if err := del.DeleteCredential(ctx, "u", "AKIA1"); err != nil {
		t.Fatalf("DeleteCredential: %v", err)
	}
}

func TestSTSClient_Methods(t *testing.T) {
	t.Parallel()

	cfg := stubCfg()
	ctx := context.Background()

	caller := &stsClient{api: sts.NewFromConfig(cfg, withSTSOpt(stubResult(&sts.GetCallerIdentityOutput{
		Account: aws.String("111122223333"),
	})))}
	acct, err := caller.CallerAccountID(ctx)
	if err != nil || acct != "111122223333" {
		t.Fatalf("CallerAccountID got %q, err %v", acct, err)
	}

	assume := &stsClient{api: sts.NewFromConfig(cfg, withSTSOpt(stubResult(&sts.AssumeRoleOutput{
		Credentials: &ststypes.Credentials{
			AccessKeyId:     aws.String("AK"),
			SecretAccessKey: aws.String("SK"),
			SessionToken:    aws.String("ST"),
			Expiration:      aws.Time(time.Date(2026, 6, 3, 1, 0, 0, 0, time.UTC)),
		},
	})))}
	creds, err := assume.AssumeRole(ctx, "arn:aws:iam::111122223333:role/r", "sess")
	if err != nil || creds.AccessKeyID != "AK" {
		t.Fatalf("AssumeRole got %+v, err %v", creds, err)
	}
}

func TestBedrockClient_Methods(t *testing.T) {
	t.Parallel()

	cfg := stubCfg()
	ctx := context.Background()

	gip := &bedrockClient{control: bedrock.NewFromConfig(cfg, withBedrockOpt(stubResult(&bedrock.GetInferenceProfileOutput{})))}
	if err := gip.GetInferenceProfile(ctx, "profile-1"); err != nil {
		t.Fatalf("GetInferenceProfile: %v", err)
	}

	put := &bedrockClient{control: bedrock.NewFromConfig(cfg, withBedrockOpt(stubResult(&bedrock.PutUseCaseForModelAccessOutput{})))}
	if err := put.PutUseCaseForModelAccess(ctx, []byte(`{}`)); err != nil {
		t.Fatalf("PutUseCaseForModelAccess: %v", err)
	}

	inv := &bedrockClient{runtime: bedrockruntime.NewFromConfig(cfg, withRuntimeOpt(stubResult(&bedrockruntime.InvokeModelOutput{})))}
	if err := inv.InvokeModel(ctx, "anthropic.claude", []byte(`{}`)); err != nil {
		t.Fatalf("InvokeModel: %v", err)
	}
}

func withOpt(o func(*middleware.Stack) error) func(*awsiam.Options) {
	return func(opts *awsiam.Options) { opts.APIOptions = append(opts.APIOptions, o) }
}

func withSTSOpt(o func(*middleware.Stack) error) func(*sts.Options) {
	return func(opts *sts.Options) { opts.APIOptions = append(opts.APIOptions, o) }
}

func withBedrockOpt(o func(*middleware.Stack) error) func(*bedrock.Options) {
	return func(opts *bedrock.Options) { opts.APIOptions = append(opts.APIOptions, o) }
}

func withRuntimeOpt(o func(*middleware.Stack) error) func(*bedrockruntime.Options) {
	return func(opts *bedrockruntime.Options) { opts.APIOptions = append(opts.APIOptions, o) }
}
