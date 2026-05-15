//go:build integration

package test

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/donaldgifford/libtftest"
	"github.com/donaldgifford/libtftest/harness"
)

// Stub VPC state values. Tests reference these directly when asserting
// that downstream resources picked up the remote-state outputs.
const (
	stubVPCID         = "vpc-libtftest"
	stubPrivateSubnet = "subnet-private-libtftest"
	stubPublicSubnet  = "subnet-public-libtftest"
	stubRegion        = "us-east-1"
)

var (
	stubPrivateSubnets = []string{stubPrivateSubnet + "-a", stubPrivateSubnet + "-b"}
	stubPublicSubnets  = []string{stubPublicSubnet + "-a", stubPublicSubnet + "-b"}
)

// stubVPCState is the JSON body uploaded to LocalStack S3 so
// data.terraform_remote_state.vpc resolves at terraform init.
// Schema: terraform state file v4 with three outputs.
type stubVPCState struct {
	Version          int                 `json:"version"`
	TerraformVersion string              `json:"terraform_version"`
	Serial           int                 `json:"serial"`
	Lineage          string              `json:"lineage"`
	Outputs          map[string]stubVal  `json:"outputs"`
	Resources        []map[string]any    `json:"resources"`
}

type stubVal struct {
	Value any `json:"value"`
	Type  any `json:"type"`
}

// newClusterTC builds a TestCase, points the terraform_remote_state s3
// backend at LocalStack via AWS_ENDPOINT_URL, seeds a stub VPC state
// file in S3, and pre-loads every required cluster module variable.
// Callers add test-specific vars via tc.SetVar before calling
// tc.Plan/Apply.
//
// AWS_ENDPOINT_URL (universal) is required because libtftest's provider
// override only redirects the aws provider — terraform_remote_state's
// s3 backend uses the AWS SDK independently, and that SDK calls STS to
// validate credentials before reading the state object. AWS_ENDPOINT_URL
// covers every service (STS included); AWS_ENDPOINT_URL_S3 alone leaves
// STS pointed at real AWS, where the synthetic "test" credentials fail.
func newClusterTC(tb testing.TB) *libtftest.TestCase {
	tb.Helper()

	opts := &libtftest.Options{ModuleDir: ".."}
	if externalContainer != nil {
		opts.Reuse = externalContainer
	}

	tc := libtftest.New(tb, opts)

	var edgeURL string
	switch {
	case externalContainer != nil:
		edgeURL = externalContainer.EdgeURL
	case harness.Current() != nil:
		edgeURL = harness.EdgeURL()
	}
	if edgeURL != "" {
		if tt, ok := tb.(interface{ Setenv(key, value string) }); ok {
			tt.Setenv("AWS_ENDPOINT_URL", edgeURL)
		}
	}

	bucket := tc.Prefix() + "-vpc-state"
	vpcName := tc.Prefix() + "-vpc"

	seedVPCState(tb, tc.AWS(), bucket, stubRegion, vpcName)

	tc.SetVar("name", tc.Prefix())
	tc.SetVar("region", stubRegion)
	tc.SetVar("remote_state_bucket", bucket)
	tc.SetVar("vpc_name", vpcName)
	tc.SetVar("tags", map[string]any{
		"Account":     "libtftest",
		"ClusterName": tc.Prefix(),
		"ClusterType": "eks",
		"Environment": "test",
		"Region":      stubRegion,
	})
	// sso_cluster_policy has no default; must be set even when SSO is
	// disabled because the validation block runs unconditionally.
	tc.SetVar("sso_cluster_policy", "AmazonEKSViewPolicy")

	return tc
}

// seedVPCState creates the LocalStack S3 bucket (idempotent) and writes a
// stub terraform.tfstate file at the key data.terraform_remote_state.vpc
// expects: <region>/vpc/<vpc_name>/terraform.tfstate.
func seedVPCState(tb testing.TB, cfg aws.Config, bucket, region, vpcName string) {
	tb.Helper()

	ctx := context.Background()
	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = true
	})

	// Bucket creation is idempotent enough for LocalStack: ignore "already
	// owned by you" / "already exists" returns. Any other error is a test
	// setup failure.
	if _, err := client.CreateBucket(ctx, &s3.CreateBucketInput{
		Bucket: aws.String(bucket),
	}); err != nil {
		tb.Logf("CreateBucket(%s): %v (continuing — may already exist)", bucket, err)
	}

	stateBody, err := json.Marshal(stubVPCState{
		Version:          4,
		TerraformVersion: "1.14.7",
		Serial:           1,
		Lineage:          "libtftest-stub",
		Outputs: map[string]stubVal{
			"vpc_id":             {Value: stubVPCID, Type: "string"},
			"private_subnet_ids": {Value: stubPrivateSubnets, Type: []any{"list", "string"}},
			"public_subnet_ids":  {Value: stubPublicSubnets, Type: []any{"list", "string"}},
		},
		Resources: []map[string]any{},
	})
	if err != nil {
		tb.Fatalf("marshal stub VPC state: %v", err)
	}

	key := region + "/vpc/" + vpcName + "/terraform.tfstate"
	if _, err := client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String(key),
		Body:        bytes.NewReader(stateBody),
		ContentType: aws.String("application/json"),
	}); err != nil {
		tb.Fatalf("PutObject %s/%s: %v", bucket, key, err)
	}

	tb.Cleanup(func() {
		// Best-effort cleanup. LocalStack tears down with the container.
		_, _ = client.DeleteObject(context.Background(), &s3.DeleteObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(key),
		})
		_, _ = client.DeleteBucket(context.Background(), &s3.DeleteBucketInput{
			Bucket: aws.String(bucket),
		})
	})
}

// planResource is the subset of a planned resource we care about.
type planResource struct {
	Address      string         `json:"address"`
	Mode         string         `json:"mode"`
	Type         string         `json:"type"`
	Name         string         `json:"name"`
	ProviderName string         `json:"provider_name"`
	Values       map[string]any `json:"values"`
}

// rootModule is the planned_values.root_module subset.
type rootModule struct {
	Resources []planResource `json:"resources"`
}

// plannedValues mirrors the planned_values top-level block.
type plannedValues struct {
	RootModule rootModule `json:"root_module"`
}

// planJSON is the subset of `terraform show -json` we read.
type planJSON struct {
	PlannedValues plannedValues          `json:"planned_values"`
	Configuration map[string]any         `json:"configuration"`
	OutputChanges map[string]outputChange `json:"output_changes"`
}

type outputChange struct {
	Actions []string `json:"actions"`
}

// parsePlan decodes the libtftest PlanResult.JSON into the subset we need.
func parsePlan(tb testing.TB, raw []byte) planJSON {
	tb.Helper()

	var p planJSON
	if err := json.Unmarshal(raw, &p); err != nil {
		tb.Fatalf("decode plan JSON: %v", err)
	}
	return p
}

// resourcesByType returns every resource (mode=="managed") of the given type.
func resourcesByType(p planJSON, resourceType string) []planResource {
	var out []planResource
	for _, r := range p.PlannedValues.RootModule.Resources {
		if r.Mode == "managed" && r.Type == resourceType {
			out = append(out, r)
		}
	}
	return out
}

// resourceByAddress returns the resource at the given address, or fails the
// test if none is found.
func resourceByAddress(tb testing.TB, p planJSON, address string) planResource {
	tb.Helper()

	for _, r := range p.PlannedValues.RootModule.Resources {
		if r.Address == address {
			return r
		}
	}
	tb.Fatalf("resource %q not in plan", address)
	return planResource{}
}

// outputsInConfig returns the names of every output declared in the
// module's configuration. Output VALUES at plan time are often unknown
// (they reference apply-computed attributes), but the names are stable.
func outputsInConfig(p planJSON) []string {
	root, ok := p.Configuration["root_module"].(map[string]any)
	if !ok {
		return nil
	}
	outs, ok := root["outputs"].(map[string]any)
	if !ok {
		return nil
	}
	names := make([]string, 0, len(outs))
	for name := range outs {
		names = append(names, name)
	}
	return names
}

// Silence unused-import warnings if a helper isn't yet referenced by tests.
var _ = types.BucketCannedACLPrivate
