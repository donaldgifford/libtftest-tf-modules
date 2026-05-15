//go:build integration

package test

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/iam"
)

// TestCluster_SSO_Disabled confirms the default path produces zero
// access-entry resources.
func TestCluster_SSO_Disabled(t *testing.T) {
	tc := newClusterTC(t)
	// var.sso_access_enabled defaults to false; no override needed.

	plan := parsePlan(t, tc.Plan().JSON)

	if got := len(resourcesByType(plan, "aws_eks_access_entry")); got != 0 {
		t.Errorf("aws_eks_access_entry count = %d; want 0 when SSO disabled", got)
	}
	if got := len(resourcesByType(plan, "aws_eks_access_policy_association")); got != 0 {
		t.Errorf("aws_eks_access_policy_association count = %d; want 0 when SSO disabled", got)
	}
}

// TestCluster_SSO_Enabled exercises the SSO Access Entry path with a seeded
// IAM role that satisfies data.aws_iam_roles.sso's regex.
//
// LocalStack Community covers IAM list/get-role enough to make
// data.aws_iam_roles resolve against a seeded AWSReservedSSO_* name.
// Per IMPL-0001 §Resolved Q7, this is the working assumption; if the
// path turns out to need full IAM Identity Center support, switch to
// the sneakystack sidecar via tftest:enable-sneakystack.
func TestCluster_SSO_Enabled(t *testing.T) {
	tc := newClusterTC(t)

	const permissionSet = "Developer"
	roleName := "AWSReservedSSO_" + permissionSet + "_libtftest"
	seedSSORole(t, tc.AWS(), roleName)

	tc.SetVar("sso_access_enabled", true)
	tc.SetVar("sso_role_name", permissionSet)
	tc.SetVar("sso_cluster_policy", "AmazonEKSViewPolicy")

	plan := parsePlan(t, tc.Plan().JSON)

	entries := resourcesByType(plan, "aws_eks_access_entry")
	if len(entries) != 1 {
		t.Fatalf("aws_eks_access_entry count = %d; want 1 when SSO enabled", len(entries))
	}

	assocs := resourcesByType(plan, "aws_eks_access_policy_association")
	if len(assocs) != 1 {
		t.Fatalf("aws_eks_access_policy_association count = %d; want 1 when SSO enabled", len(assocs))
	}

	if got, _ := assocs[0].Values["policy_arn"].(string); !strings.HasSuffix(got, "/AmazonEKSViewPolicy") {
		t.Errorf("policy_arn = %q; want suffix /AmazonEKSViewPolicy", got)
	}
}

// seedSSORole creates an IAM role whose name matches the
// AWSReservedSSO_<permission-set>_* pattern that the cluster module's
// data.aws_iam_roles.sso lookup expects.
func seedSSORole(tb testing.TB, cfg aws.Config, name string) {
	tb.Helper()

	ctx := context.Background()
	client := iam.NewFromConfig(cfg)

	trust := `{
		"Version": "2012-10-17",
		"Statement": [
			{"Effect": "Allow", "Principal": {"Service": "sso.amazonaws.com"}, "Action": "sts:AssumeRole"}
		]
	}`

	if _, err := client.CreateRole(ctx, &iam.CreateRoleInput{
		RoleName:                 aws.String(name),
		AssumeRolePolicyDocument: aws.String(trust),
		Path:                     aws.String("/aws-reserved/sso.amazonaws.com/"),
	}); err != nil {
		tb.Fatalf("seed SSO role %q: %v", name, err)
	}

	tb.Cleanup(func() {
		_, _ = client.DeleteRole(context.Background(), &iam.DeleteRoleInput{
			RoleName: aws.String(name),
		})
	})
}
