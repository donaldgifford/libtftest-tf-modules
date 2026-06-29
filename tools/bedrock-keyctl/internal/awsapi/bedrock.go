package awsapi

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/bedrock"
	bedrocktypes "github.com/aws/aws-sdk-go-v2/service/bedrock/types"
	"github.com/aws/aws-sdk-go-v2/service/bedrockruntime"
	runtimetypes "github.com/aws/aws-sdk-go-v2/service/bedrockruntime/types"
	smithybearer "github.com/aws/smithy-go/auth/bearer"
)

// Domain sentinels translated from SDK exceptions so callers (the
// enablement package) stay free of SDK error coupling.
var (
	// ErrUseCaseAlreadyExists signals the Anthropic use-case form was
	// already submitted for this account — enablement is a no-op.
	ErrUseCaseAlreadyExists = errors.New("bedrock use-case form already submitted")
	// ErrAlreadySubscribed signals the principal is already subscribed
	// to the model's Marketplace listing — Path C enablement is a no-op.
	ErrAlreadySubscribed = errors.New("already subscribed to the model's Marketplace listing")
	// ErrModelInputRejected signals an InvokeModel call reached input
	// validation: the principal HAS model access (it is past the
	// Marketplace subscribe gate), only the request body was rejected.
	// Path C treats this as proof of access.
	ErrModelInputRejected = errors.New("model invocation reached input validation (access granted, body rejected)")
)

// BedrockClient covers the three Bedrock operations the tool needs:
// inference-profile verification (rotate), the Anthropic use-case form
// (enable-models Path A), and a model invocation (the Path C
// Marketplace auto-subscribe trigger).
type BedrockClient interface {
	// GetInferenceProfile returns an error if the profile cannot be
	// read — used by rotate to prove a freshly minted credential works.
	GetInferenceProfile(ctx context.Context, profileID string) error
	// PutUseCaseForModelAccess submits the one-time Anthropic use-case
	// form (idempotent on the AWS side).
	PutUseCaseForModelAccess(ctx context.Context, formData []byte) error
	// InvokeModel issues a minimal invocation, used to trigger the
	// first-invocation Marketplace auto-subscribe for third-party
	// providers (Path C invocation sub-path).
	InvokeModel(ctx context.Context, modelID string, body []byte) error
}

// bedrockClient is the SDK-backed BedrockClient. It holds both the
// control-plane client (profiles, use-case form) and the runtime client
// (InvokeModel).
type bedrockClient struct {
	control *bedrock.Client
	runtime *bedrockruntime.Client
}

var _ BedrockClient = (*bedrockClient)(nil)

// NewBedrockClient builds a BedrockClient from an AWS config.
func NewBedrockClient(cfg *aws.Config) BedrockClient {
	return &bedrockClient{
		control: bedrock.NewFromConfig(*cfg),
		runtime: bedrockruntime.NewFromConfig(*cfg),
	}
}

// NewBedrockClientWithToken builds a BedrockClient that authenticates
// with a Bedrock bearer token rather than SigV4 — the same auth path
// Claude Code uses via AWS_BEARER_TOKEN_BEDROCK. rotate uses it to
// verify a freshly minted credential works before retiring the old one,
// exercising the exact credential the consumer will load.
func NewBedrockClientWithToken(region, token string) BedrockClient {
	tp := smithybearer.StaticTokenProvider{Token: smithybearer.Token{Value: token}}
	return &bedrockClient{
		control: bedrock.New(bedrock.Options{
			Region:                  region,
			BearerAuthTokenProvider: tp,
		}),
		runtime: bedrockruntime.New(bedrockruntime.Options{
			Region:                  region,
			BearerAuthTokenProvider: tp,
		}),
	}
}

func (c *bedrockClient) GetInferenceProfile(ctx context.Context, profileID string) error {
	_, err := c.control.GetInferenceProfile(ctx, &bedrock.GetInferenceProfileInput{
		InferenceProfileIdentifier: aws.String(profileID),
	})
	if err != nil {
		return fmt.Errorf("get inference profile %s: %w", profileID, err)
	}
	return nil
}

func (c *bedrockClient) PutUseCaseForModelAccess(ctx context.Context, formData []byte) error {
	_, err := c.control.PutUseCaseForModelAccess(ctx, &bedrock.PutUseCaseForModelAccessInput{
		FormData: formData,
	})
	return classifyPutUseCaseErr(err)
}

// classifyPutUseCaseErr maps a PutUseCaseForModelAccess error to a
// domain result: nil stays nil, a ConflictException becomes the
// idempotent ErrUseCaseAlreadyExists sentinel, anything else is wrapped.
func classifyPutUseCaseErr(err error) error {
	if err == nil {
		return nil
	}
	var conflict *bedrocktypes.ConflictException
	if errors.As(err, &conflict) {
		return ErrUseCaseAlreadyExists
	}
	return fmt.Errorf("put use-case for model access: %w", err)
}

func (c *bedrockClient) InvokeModel(ctx context.Context, modelID string, body []byte) error {
	_, err := c.runtime.InvokeModel(ctx, &bedrockruntime.InvokeModelInput{
		ModelId:     aws.String(modelID),
		Body:        body,
		ContentType: aws.String("application/json"),
		Accept:      aws.String("application/json"),
	})
	return classifyInvokeErr(modelID, err)
}

// classifyInvokeErr maps an InvokeModel error to a domain result: a
// ConflictException becomes ErrAlreadySubscribed, a ValidationException
// becomes ErrModelInputRejected (access granted, body rejected), and
// anything else is wrapped.
func classifyInvokeErr(modelID string, err error) error {
	if err == nil {
		return nil
	}
	var conflict *runtimetypes.ConflictException
	if errors.As(err, &conflict) {
		return ErrAlreadySubscribed
	}
	var validation *runtimetypes.ValidationException
	if errors.As(err, &validation) {
		return ErrModelInputRejected
	}
	return fmt.Errorf("invoke model %s: %w", modelID, err)
}
