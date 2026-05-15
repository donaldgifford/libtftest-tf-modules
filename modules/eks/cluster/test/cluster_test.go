//go:build integration

package test

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestCluster_DefaultPlan exercises every plan-time invariant from
// DESIGN-0002 §Testing Strategy that doesn't depend on the SSO path.
// Tests share a single Plan call to keep wall time down.
//
// Note: every test in this package uses t.Setenv (via newClusterTC) which
// is incompatible with t.Parallel. Tests run sequentially.
func TestCluster_DefaultPlan(t *testing.T) {
	tc := newClusterTC(t)
	plan := parsePlan(t, tc.Plan().JSON)

	t.Run("no_eks_addons", func(t *testing.T) {
		if got := len(resourcesByType(plan, "aws_eks_addon")); got != 0 {
			t.Errorf("plan contains %d aws_eks_addon resources; want 0 (ADR-0003 — addons live in DESIGN-0003)", got)
		}
	})

	t.Run("only_cluster_service_iam_role", func(t *testing.T) {
		roles := resourcesByType(plan, "aws_iam_role")
		if len(roles) != 1 {
			t.Errorf("plan contains %d aws_iam_role resources; want 1 (cluster service role only; workload IAM lives in DESIGN-0004)", len(roles))
		}
		if len(roles) == 1 && roles[0].Address != "aws_iam_role.cluster" {
			t.Errorf("unexpected aws_iam_role address %q; want aws_iam_role.cluster", roles[0].Address)
		}
	})

	t.Run("cluster_service_role_trusts_eks_service", func(t *testing.T) {
		role := resourceByAddress(t, plan, "aws_iam_role.cluster")
		trust, _ := role.Values["assume_role_policy"].(string)
		if !strings.Contains(trust, `"eks.amazonaws.com"`) {
			t.Errorf("aws_iam_role.cluster trust policy missing eks.amazonaws.com:\n%s", trust)
		}
	})

	t.Run("kms_envelope_encryption", func(t *testing.T) {
		cluster := resourceByAddress(t, plan, "aws_eks_cluster.this")
		ec, ok := cluster.Values["encryption_config"].([]any)
		if !ok || len(ec) == 0 {
			t.Fatalf("aws_eks_cluster.this.encryption_config missing or empty")
		}
		ecm, _ := ec[0].(map[string]any)
		resources, _ := ecm["resources"].([]any)
		var hasSecrets bool
		for _, r := range resources {
			if r == "secrets" {
				hasSecrets = true
			}
		}
		if !hasSecrets {
			t.Errorf("encryption_config.resources missing %q; got %v", "secrets", resources)
		}
		// provider.key_arn may be (known after apply) when the module
		// manages its own KMS key — in that case the values map has the
		// key but its value is the literal nil. We just confirm the
		// provider block exists.
		if _, has := ecm["provider"]; !has {
			t.Errorf("encryption_config[0].provider not present")
		}
	})

	t.Run("endpoint_defaults", func(t *testing.T) {
		cluster := resourceByAddress(t, plan, "aws_eks_cluster.this")
		vpcConfig, _ := cluster.Values["vpc_config"].([]any)
		if len(vpcConfig) == 0 {
			t.Fatalf("vpc_config missing")
		}
		vc, _ := vpcConfig[0].(map[string]any)
		if got := vc["endpoint_public_access"]; got != true {
			t.Errorf("endpoint_public_access = %v; want true", got)
		}
		if got := vc["endpoint_private_access"]; got != true {
			t.Errorf("endpoint_private_access = %v; want true", got)
		}
	})

	t.Run("authentication_mode_api_and_config_map", func(t *testing.T) {
		cluster := resourceByAddress(t, plan, "aws_eks_cluster.this")
		ac, _ := cluster.Values["access_config"].([]any)
		if len(ac) == 0 {
			t.Fatalf("access_config missing")
		}
		acm, _ := ac[0].(map[string]any)
		if got := acm["authentication_mode"]; got != "API_AND_CONFIG_MAP" {
			t.Errorf("authentication_mode = %v; want API_AND_CONFIG_MAP", got)
		}
	})

	t.Run("log_retention_30_days", func(t *testing.T) {
		lg := resourceByAddress(t, plan, "aws_cloudwatch_log_group.cluster")
		// JSON numbers decode to float64.
		got, _ := lg.Values["retention_in_days"].(float64)
		if got != 30 {
			t.Errorf("retention_in_days = %v; want 30", got)
		}
		if name, _ := lg.Values["name"].(string); !strings.HasSuffix(name, "/cluster") {
			t.Errorf("log group name %q does not end with /cluster", name)
		}
	})

	t.Run("kms_key_rotation_enabled", func(t *testing.T) {
		// Module-managed KMS path (var.kms_key_arn unset → count = 1).
		keys := resourcesByType(plan, "aws_kms_key")
		if len(keys) != 1 {
			t.Fatalf("aws_kms_key count = %d; want 1 when var.kms_key_arn is null", len(keys))
		}
		if got, _ := keys[0].Values["enable_key_rotation"].(bool); !got {
			t.Errorf("aws_kms_key.cluster: enable_key_rotation = %v; want true", got)
		}
		if got, _ := keys[0].Values["deletion_window_in_days"].(float64); got != 30 {
			t.Errorf("aws_kms_key.cluster: deletion_window_in_days = %v; want 30", got)
		}
	})

	t.Run("node_sg_uses_remote_state_vpc", func(t *testing.T) {
		sg := resourceByAddress(t, plan, "aws_security_group.nodes")
		if got, _ := sg.Values["vpc_id"].(string); got != stubVPCID {
			t.Errorf("aws_security_group.nodes: vpc_id = %q; want %q (from stub remote state)", got, stubVPCID)
		}
	})

	t.Run("outputs_contract", func(t *testing.T) {
		want := []string{
			"cluster_name",
			"cluster_version",
			"cluster_endpoint",
			"cluster_ca_data",
			"cluster_oidc_issuer_url",
			"cluster_security_group_id",
			"node_security_group_id",
			"kms_key_arn",
		}
		got := outputsInConfig(plan)
		gotSet := make(map[string]bool, len(got))
		for _, n := range got {
			gotSet[n] = true
		}
		for _, n := range want {
			if !gotSet[n] {
				t.Errorf("module is missing output %q", n)
			}
		}
		if len(got) != len(want) {
			t.Errorf("output count = %d; want %d. got=%v", len(got), len(want), got)
		}
	})
}

// TestCluster_KMS_External verifies that passing an external KMS key ARN
// disables the module-managed CMK path (count = 0 on aws_kms_key.cluster).
func TestCluster_KMS_External(t *testing.T) {
	tc := newClusterTC(t)
	const externalKMS = "arn:aws:kms:us-east-1:000000000000:key/external"
	tc.SetVar("kms_key_arn", externalKMS)

	plan := parsePlan(t, tc.Plan().JSON)

	if got := len(resourcesByType(plan, "aws_kms_key")); got != 0 {
		t.Errorf("aws_kms_key count = %d; want 0 when var.kms_key_arn is set", got)
	}
	if got := len(resourcesByType(plan, "aws_kms_alias")); got != 0 {
		t.Errorf("aws_kms_alias count = %d; want 0 when var.kms_key_arn is set", got)
	}

	// kms_key_arn output must still flow the external value through. The
	// output's planned value is the literal var, so it's known at plan time.
	output, err := json.Marshal(plan.PlannedValues)
	if err != nil {
		t.Fatalf("re-marshal plan: %v", err)
	}
	if !strings.Contains(string(output), externalKMS) {
		t.Errorf("plan does not reference external KMS ARN %q anywhere", externalKMS)
	}
}
