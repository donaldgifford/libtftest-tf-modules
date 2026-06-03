package sink

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	smtypes "github.com/aws/aws-sdk-go-v2/service/secretsmanager/types"
)

// secretsManagerAPI is the subset of the Secrets Manager SDK client the
// sink uses. Defined as an interface so the sink's create-then-put
// logic is unit-testable against an in-memory fake (no SDK types leak
// past the sink package).
type secretsManagerAPI interface {
	CreateSecret(ctx context.Context, in *secretsmanager.CreateSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.CreateSecretOutput, error)
	PutSecretValue(ctx context.Context, in *secretsmanager.PutSecretValueInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.PutSecretValueOutput, error)
	GetSecretValue(ctx context.Context, in *secretsmanager.GetSecretValueInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.GetSecretValueOutput, error)
	DeleteSecret(ctx context.Context, in *secretsmanager.DeleteSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.DeleteSecretOutput, error)
}

// SecretsManagerSink stores credential envelopes in AWS Secrets Manager
// (the default v1 sink per DESIGN-0009 Q7).
type SecretsManagerSink struct {
	api secretsManagerAPI
}

var _ Sink = (*SecretsManagerSink)(nil)

// NewSecretsManagerSink builds a Secrets Manager sink from an AWS config.
func NewSecretsManagerSink(cfg *aws.Config) *SecretsManagerSink {
	return &SecretsManagerSink{api: secretsmanager.NewFromConfig(*cfg)}
}

// Write creates the secret on first write and updates its value on
// subsequent writes (the SM contract: CreateSecret for a new name,
// PutSecretValue to add a version to an existing one).
func (s *SecretsManagerSink) Write(ctx context.Context, key string, payload []byte) error {
	_, err := s.api.CreateSecret(ctx, &secretsmanager.CreateSecretInput{
		Name:         aws.String(key),
		SecretString: aws.String(string(payload)),
	})
	if err == nil {
		return nil
	}

	var exists *smtypes.ResourceExistsException
	if !errors.As(err, &exists) {
		return fmt.Errorf("create secret %q: %w", key, err)
	}

	if _, putErr := s.api.PutSecretValue(ctx, &secretsmanager.PutSecretValueInput{
		SecretId:     aws.String(key),
		SecretString: aws.String(string(payload)),
	}); putErr != nil {
		return fmt.Errorf("put secret value %q: %w", key, putErr)
	}
	return nil
}

// Read returns the latest secret string stored under key.
func (s *SecretsManagerSink) Read(ctx context.Context, key string) ([]byte, error) {
	out, err := s.api.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(key),
	})
	if err != nil {
		return nil, fmt.Errorf("get secret value %q: %w", key, err)
	}
	return []byte(aws.ToString(out.SecretString)), nil
}

// Delete removes the secret immediately (no recovery window): the IAM
// credential is deleted first by revoke, so the stored envelope is
// already useless.
func (s *SecretsManagerSink) Delete(ctx context.Context, key string) error {
	_, err := s.api.DeleteSecret(ctx, &secretsmanager.DeleteSecretInput{
		SecretId:                   aws.String(key),
		ForceDeleteWithoutRecovery: aws.Bool(true),
	})
	if err != nil {
		return fmt.Errorf("delete secret %q: %w", key, err)
	}
	return nil
}
