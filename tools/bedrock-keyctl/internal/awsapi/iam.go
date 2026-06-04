// Package awsapi defines the narrow, mockable interfaces the
// bedrock-keyctl subcommands use to reach AWS, plus thin SDK-backed
// implementations. Each interface speaks domain types (Credential,
// CreatedCredential, ...) rather than AWS SDK input/output structs, so
// mocks in tests carry no SDK coupling (DESIGN-0009 §2, Uber style).
package awsapi

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsiam "github.com/aws/aws-sdk-go-v2/service/iam"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/credential"
)

// BedrockServiceName is the IAM service-specific credential service for
// the Bedrock bearer token Claude Code consumes.
const BedrockServiceName = "bedrock.amazonaws.com"

// Credential status values.
const (
	StatusActive   = "Active"
	StatusInactive = "Inactive"
)

// ErrCredentialNotFound is returned when a named credential does not
// exist on the user.
var ErrCredentialNotFound = errors.New("service-specific credential not found")

// Credential is the identity metadata for an IAM service-specific
// credential — never the secret.
type Credential struct {
	ID        string
	UserName  string
	Status    string
	CreatedAt time.Time
	ExpiresAt time.Time
}

// CreatedCredential carries the one-time secret alongside the identity
// fields, returned only by CreateCredential. The secret is opaque (see
// the credential package) and reachable only by a sink.
type CreatedCredential struct {
	Credential
	Secret credential.SecretValue
}

// IAMClient manages the Bedrock service-specific credential lifecycle.
type IAMClient interface {
	// CreateCredential mints a new bedrock.amazonaws.com credential on
	// the user. ageDays <= 0 lets AWS apply its default expiry.
	CreateCredential(ctx context.Context, userName string, ageDays int32) (CreatedCredential, error)
	// ListCredentials returns the user's bedrock.amazonaws.com
	// credentials (metadata only).
	ListCredentials(ctx context.Context, userName string) ([]Credential, error)
	// SetCredentialStatus sets a credential Active or Inactive.
	SetCredentialStatus(ctx context.Context, userName, credentialID, status string) error
	// DeleteCredential permanently removes a credential.
	DeleteCredential(ctx context.Context, userName, credentialID string) error
}

// iamClient is the SDK-backed IAMClient.
type iamClient struct {
	api *awsiam.Client
}

var _ IAMClient = (*iamClient)(nil)

// NewIAMClient builds an IAMClient from an AWS config.
func NewIAMClient(cfg *aws.Config) IAMClient {
	return &iamClient{api: awsiam.NewFromConfig(*cfg)}
}

func (c *iamClient) CreateCredential(ctx context.Context, userName string, ageDays int32) (CreatedCredential, error) {
	in := &awsiam.CreateServiceSpecificCredentialInput{
		UserName:    aws.String(userName),
		ServiceName: aws.String(BedrockServiceName),
	}
	if ageDays > 0 {
		in.CredentialAgeDays = aws.Int32(ageDays)
	}

	out, err := c.api.CreateServiceSpecificCredential(ctx, in)
	if err != nil {
		return CreatedCredential{}, fmt.Errorf("create service-specific credential: %w", err)
	}

	ssc := out.ServiceSpecificCredential
	return CreatedCredential{
		Credential: Credential{
			ID:        aws.ToString(ssc.ServiceSpecificCredentialId),
			UserName:  aws.ToString(ssc.UserName),
			Status:    string(ssc.Status),
			CreatedAt: aws.ToTime(ssc.CreateDate),
			ExpiresAt: aws.ToTime(ssc.ExpirationDate),
		},
		// ServiceCredentialSecret is the bearer-token value for
		// bedrock.amazonaws.com credentials.
		Secret: credential.NewSecretValue(aws.ToString(ssc.ServiceCredentialSecret)),
	}, nil
}

func (c *iamClient) ListCredentials(ctx context.Context, userName string) ([]Credential, error) {
	out, err := c.api.ListServiceSpecificCredentials(ctx, &awsiam.ListServiceSpecificCredentialsInput{
		UserName:    aws.String(userName),
		ServiceName: aws.String(BedrockServiceName),
	})
	if err != nil {
		return nil, fmt.Errorf("list service-specific credentials: %w", err)
	}

	creds := make([]Credential, 0, len(out.ServiceSpecificCredentials))
	for i := range out.ServiceSpecificCredentials {
		m := out.ServiceSpecificCredentials[i]
		creds = append(creds, Credential{
			ID:        aws.ToString(m.ServiceSpecificCredentialId),
			UserName:  aws.ToString(m.UserName),
			Status:    string(m.Status),
			CreatedAt: aws.ToTime(m.CreateDate),
			ExpiresAt: aws.ToTime(m.ExpirationDate),
		})
	}
	return creds, nil
}

func (c *iamClient) SetCredentialStatus(ctx context.Context, userName, credentialID, status string) error {
	_, err := c.api.UpdateServiceSpecificCredential(ctx, &awsiam.UpdateServiceSpecificCredentialInput{
		UserName:                    aws.String(userName),
		ServiceSpecificCredentialId: aws.String(credentialID),
		Status:                      iamtypes.StatusType(status),
	})
	if err != nil {
		return fmt.Errorf("update service-specific credential status to %s: %w", status, err)
	}
	return nil
}

func (c *iamClient) DeleteCredential(ctx context.Context, userName, credentialID string) error {
	_, err := c.api.DeleteServiceSpecificCredential(ctx, &awsiam.DeleteServiceSpecificCredentialInput{
		UserName:                    aws.String(userName),
		ServiceSpecificCredentialId: aws.String(credentialID),
	})
	if err != nil {
		return fmt.Errorf("delete service-specific credential: %w", err)
	}
	return nil
}
