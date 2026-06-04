package awsapi

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

// AssumedCredentials are the temporary credentials returned by an
// AssumeRole call, used to build clients for a cross-account target.
type AssumedCredentials struct {
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
	Expiration      time.Time
}

// STSClient resolves the caller identity and assumes cross-account
// roles for enable-models targeting.
type STSClient interface {
	// CallerAccountID returns the account ID of the ambient principal.
	CallerAccountID(ctx context.Context) (string, error)
	// AssumeRole assumes roleARN and returns its temporary credentials.
	AssumeRole(ctx context.Context, roleARN, sessionName string) (AssumedCredentials, error)
}

// stsClient is the SDK-backed STSClient.
type stsClient struct {
	api *sts.Client
}

var _ STSClient = (*stsClient)(nil)

// NewSTSClient builds an STSClient from an AWS config.
func NewSTSClient(cfg *aws.Config) STSClient {
	return &stsClient{api: sts.NewFromConfig(*cfg)}
}

func (c *stsClient) CallerAccountID(ctx context.Context) (string, error) {
	out, err := c.api.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		return "", fmt.Errorf("get caller identity: %w", err)
	}
	return aws.ToString(out.Account), nil
}

func (c *stsClient) AssumeRole(ctx context.Context, roleARN, sessionName string) (AssumedCredentials, error) {
	out, err := c.api.AssumeRole(ctx, &sts.AssumeRoleInput{
		RoleArn:         aws.String(roleARN),
		RoleSessionName: aws.String(sessionName),
	})
	if err != nil {
		return AssumedCredentials{}, fmt.Errorf("assume role %s: %w", roleARN, err)
	}

	creds := out.Credentials
	return AssumedCredentials{
		AccessKeyID:     aws.ToString(creds.AccessKeyId),
		SecretAccessKey: aws.ToString(creds.SecretAccessKey),
		SessionToken:    aws.ToString(creds.SessionToken),
		Expiration:      aws.ToTime(creds.Expiration),
	}, nil
}
