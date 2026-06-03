package cmd

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
)

// loadAWSConfig resolves the ambient AWS config, overriding the region
// when --region is set. Used by the single-account subcommands (mint,
// rotate, revoke); enable-models builds its own per-target configs.
func loadAWSConfig(ctx context.Context, region string) (aws.Config, error) {
	var opts []func(*config.LoadOptions) error
	if region != "" {
		opts = append(opts, config.WithRegion(region))
	}

	cfg, err := config.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return aws.Config{}, fmt.Errorf("load AWS config: %w", err)
	}
	return cfg, nil
}

// configForCredentials clones base with its credentials swapped for the
// static AssumeRole credentials of a cross-account target.
func configForCredentials(base *aws.Config, creds awsapi.AssumedCredentials) aws.Config {
	cfg := *base
	cfg.Credentials = credentials.NewStaticCredentialsProvider(
		creds.AccessKeyID, creds.SecretAccessKey, creds.SessionToken)
	return cfg
}
