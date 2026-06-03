package enablement

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
)

func TestEnableAnthropic(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		putErr  error
		want    Outcome
		wantErr bool
	}{
		{name: "first submit enables", putErr: nil, want: OutcomeEnabled},
		{name: "already submitted is no-action", putErr: awsapi.ErrUseCaseAlreadyExists, want: OutcomeNoActionNeeded},
		{name: "hard error fails", putErr: errors.New("denied"), want: OutcomeFailed, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			bc := &awsapi.MockBedrockClient{PutUseCaseErr: tt.putErr}
			r := EnableAnthropic(context.Background(), bc, "anthropic.claude")

			if r.Outcome != tt.want {
				t.Errorf("Outcome = %q, want %q", r.Outcome, tt.want)
			}
			if (r.Err != nil) != tt.wantErr {
				t.Errorf("Err = %v, wantErr %v", r.Err, tt.wantErr)
			}
			if bc.PutUseCaseCount != 1 {
				t.Errorf("PutUseCaseForModelAccess called %d times, want 1", bc.PutUseCaseCount)
			}
			if r.Provider != "anthropic" {
				t.Errorf("Provider = %q, want anthropic", r.Provider)
			}
		})
	}
}

func TestEnableAmazon_NoOp(t *testing.T) {
	t.Parallel()

	r := EnableAmazon(context.Background(), "amazon.nova-pro")
	if r.Outcome != OutcomeNoActionNeeded {
		t.Errorf("Outcome = %q, want no-action-needed", r.Outcome)
	}
	if r.Provider != "amazon" {
		t.Errorf("Provider = %q, want amazon", r.Provider)
	}
}

func TestEnableMarketplace_Paths(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name         string
		path         SubscribePath
		subscribed   bool
		subscribeErr error
		invokeErr    error
		want         Outcome
		wantSubCalls int
		wantInvCalls int
	}{
		{
			name: "auto: explicit subscribe succeeds",
			path: SubscribeAuto, subscribeErr: nil,
			want: OutcomeEnabled, wantSubCalls: 1, wantInvCalls: 0,
		},
		{
			name: "auto: unsupported falls back to invocation",
			path: SubscribeAuto, subscribeErr: awsapi.ErrSubscribeUnsupported,
			want: OutcomeEnabled, wantSubCalls: 1, wantInvCalls: 1,
		},
		{
			name: "auto: already subscribed (explicit) is no-action",
			path: SubscribeAuto, subscribeErr: awsapi.ErrAlreadySubscribed,
			want: OutcomeNoActionNeeded, wantSubCalls: 1, wantInvCalls: 0,
		},
		{
			name: "auto: hard subscribe error fails",
			path: SubscribeAuto, subscribeErr: errors.New("denied"),
			want: OutcomeFailed, wantSubCalls: 1, wantInvCalls: 0,
		},
		{
			name: "pre-check already subscribed short-circuits",
			path: SubscribeAuto, subscribed: true,
			want: OutcomeNoActionNeeded, wantSubCalls: 0, wantInvCalls: 0,
		},
		{
			name: "explicit only",
			path: SubscribeExplicit, subscribeErr: nil,
			want: OutcomeEnabled, wantSubCalls: 1, wantInvCalls: 0,
		},
		{
			name: "invocation only",
			path: SubscribeInvocation, invokeErr: nil,
			want: OutcomeEnabled, wantSubCalls: 0, wantInvCalls: 1,
		},
		{
			name: "invocation: input-rejected means access granted",
			path: SubscribeInvocation, invokeErr: awsapi.ErrModelInputRejected,
			want: OutcomeEnabled, wantSubCalls: 0, wantInvCalls: 1,
		},
		{
			name: "invocation: already subscribed is no-action",
			path: SubscribeInvocation, invokeErr: awsapi.ErrAlreadySubscribed,
			want: OutcomeNoActionNeeded, wantSubCalls: 0, wantInvCalls: 1,
		},
		{
			name: "invocation: hard error fails",
			path: SubscribeInvocation, invokeErr: errors.New("throttled"),
			want: OutcomeFailed, wantSubCalls: 0, wantInvCalls: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			mkt := &awsapi.MockMarketplaceClient{Subscribed: tt.subscribed, SubscribeErr: tt.subscribeErr}
			bc := &awsapi.MockBedrockClient{InvokeErr: tt.invokeErr}
			spec := ModelSpec{Provider: "meta", ModelID: "meta.llama"}

			r := EnableMarketplace(context.Background(), mkt, bc, spec, tt.path)

			if r.Outcome != tt.want {
				t.Errorf("Outcome = %q, want %q (action %q, err %v)", r.Outcome, tt.want, r.Action, r.Err)
			}
			if mkt.SubscribeCount != tt.wantSubCalls {
				t.Errorf("Subscribe calls = %d, want %d", mkt.SubscribeCount, tt.wantSubCalls)
			}
			if bc.InvokeCount != tt.wantInvCalls {
				t.Errorf("Invoke calls = %d, want %d", bc.InvokeCount, tt.wantInvCalls)
			}
		})
	}
}

func TestEnableMarketplace_InvalidPath(t *testing.T) {
	t.Parallel()

	r := EnableMarketplace(context.Background(),
		&awsapi.MockMarketplaceClient{}, &awsapi.MockBedrockClient{},
		ModelSpec{Provider: "meta", ModelID: "meta.llama"}, SubscribePath("bogus"))
	if r.Outcome != OutcomeFailed {
		t.Errorf("Outcome = %q, want failed for invalid path", r.Outcome)
	}
}

func TestEnabler_Dispatch(t *testing.T) {
	t.Parallel()

	enabler := NewEnabler(&awsapi.MockBedrockClient{}, &awsapi.MockMarketplaceClient{}, SubscribeAuto)
	ctx := context.Background()

	cases := map[string]struct {
		spec ModelSpec
		want Outcome
	}{
		"anthropic":        {ModelSpec{"anthropic", "anthropic.claude"}, OutcomeEnabled},
		"amazon":           {ModelSpec{"amazon", "amazon.nova"}, OutcomeNoActionNeeded},
		"marketplace meta": {ModelSpec{"meta", "meta.llama"}, OutcomeEnabled},
		"unknown provider": {ModelSpec{"acme", "acme.x"}, OutcomeFailed},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if r := enabler.Enable(ctx, tc.spec); r.Outcome != tc.want {
				t.Errorf("Enable(%v).Outcome = %q, want %q", tc.spec, r.Outcome, tc.want)
			}
		})
	}
}

func TestEnableAll_DelegatesWithoutCascade(t *testing.T) {
	t.Parallel()

	enabler := NewEnabler(&awsapi.MockBedrockClient{}, &awsapi.MockMarketplaceClient{}, SubscribeAuto)
	results := enabler.EnableAll(context.Background(), []ModelSpec{
		{Provider: "amazon", ModelID: "amazon.nova"},
		{Provider: "meta", ModelID: "meta.llama"},
	})
	if len(results) != 2 {
		t.Fatalf("got %d results, want 2", len(results))
	}
	// Without cascade restriction, the meta model is dispatched (enabled),
	// not warned.
	if results[1].Outcome == OutcomeWarning {
		t.Error("EnableAll should not apply the org-cascade warning")
	}
}

func TestEnableAllForTarget_CascadeOnlyAnthropic(t *testing.T) {
	t.Parallel()

	enabler := NewEnabler(&awsapi.MockBedrockClient{}, &awsapi.MockMarketplaceClient{}, SubscribeAuto)
	specs := []ModelSpec{
		{Provider: "anthropic", ModelID: "anthropic.claude"},
		{Provider: "meta", ModelID: "meta.llama"},
	}

	results := enabler.EnableAllForTarget(context.Background(), specs, true)
	if len(results) != 2 {
		t.Fatalf("got %d results, want 2", len(results))
	}
	if results[0].Outcome != OutcomeEnabled {
		t.Errorf("anthropic outcome = %q, want enabled (cascades)", results[0].Outcome)
	}
	if results[1].Outcome != OutcomeWarning {
		t.Errorf("meta outcome = %q, want warning (no cascade)", results[1].Outcome)
	}
}

func TestFirstFailure(t *testing.T) {
	t.Parallel()

	none := []Result{{Outcome: OutcomeEnabled}, {Outcome: OutcomeWarning}, {Outcome: OutcomeNoActionNeeded}}
	if err := FirstFailure(none); err != nil {
		t.Errorf("FirstFailure = %v, want nil (warning is non-fatal)", err)
	}

	some := []Result{{Outcome: OutcomeEnabled}, {Model: "m", Provider: "p", Outcome: OutcomeFailed, Err: errors.New("boom")}}
	if err := FirstFailure(some); err == nil {
		t.Error("FirstFailure = nil, want the failed model's error")
	}
}

func TestParseModelsCSV(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		in      string
		want    []ModelSpec
		wantErr bool
	}{
		{
			name: "single pair",
			in:   "anthropic.claude-3-5-sonnet",
			want: []ModelSpec{{"anthropic", "claude-3-5-sonnet"}},
		},
		{
			name: "multiple pairs with spaces",
			in:   "anthropic.claude, meta.llama",
			want: []ModelSpec{{"anthropic", "claude"}, {"meta", "llama"}},
		},
		{
			name: "model id keeps later dots and colon",
			in:   "anthropic.claude-3-5-sonnet-20241022-v2:0",
			want: []ModelSpec{{"anthropic", "claude-3-5-sonnet-20241022-v2:0"}},
		},
		{name: "no dot is invalid", in: "anthropic", wantErr: true},
		{name: "empty provider invalid", in: ".claude", wantErr: true},
		{name: "empty model invalid", in: "anthropic.", wantErr: true},
		{name: "empty string invalid", in: "", wantErr: true},
		{name: "only commas invalid", in: ",,", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := ParseModelsCSV(tt.in)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("ParseModelsCSV(%q) = nil err, want error", tt.in)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseModelsCSV(%q): %v", tt.in, err)
			}
			if !equalSpecs(got, tt.want) {
				t.Errorf("ParseModelsCSV(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}

func TestParseModelsJSON(t *testing.T) {
	t.Parallel()

	good := `[{"provider":"anthropic","model_id":"anthropic.claude"},{"provider":"meta","model_id":"meta.llama"}]`
	got, err := ParseModelsJSON([]byte(good))
	if err != nil {
		t.Fatalf("ParseModelsJSON: %v", err)
	}
	want := []ModelSpec{{"anthropic", "anthropic.claude"}, {"meta", "meta.llama"}}
	if !equalSpecs(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}

	for _, bad := range []string{
		`not json`,
		`[]`,
		`[{"provider":"","model_id":"x"}]`,
		`[{"provider":"anthropic","model_id":""}]`,
	} {
		if _, err := ParseModelsJSON([]byte(bad)); err == nil {
			t.Errorf("ParseModelsJSON(%q) = nil err, want error", bad)
		}
	}
}

func TestValidSubscribePath(t *testing.T) {
	t.Parallel()

	for _, p := range []SubscribePath{SubscribeAuto, SubscribeExplicit, SubscribeInvocation} {
		if !ValidSubscribePath(p) {
			t.Errorf("ValidSubscribePath(%q) = false, want true", p)
		}
	}
	if ValidSubscribePath("nope") {
		t.Error("ValidSubscribePath(nope) = true, want false")
	}
}

func TestPrintResults_TableAndErrors(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	results := []Result{
		{Model: "anthropic.claude", Provider: "anthropic", Action: "use-case-form", Outcome: OutcomeEnabled},
		{Model: "acme.x", Provider: "acme", Action: "none", Outcome: OutcomeFailed, Err: errors.New("unknown provider")},
	}
	if err := PrintResults(&buf, results); err != nil {
		t.Fatalf("PrintResults: %v", err)
	}

	out := buf.String()
	for _, want := range []string{"MODEL", "PROVIDER", "ACTION", "OUTCOME", "anthropic.claude", "enabled", "failed", "unknown provider"} {
		if !strings.Contains(out, want) {
			t.Errorf("table missing %q:\n%s", want, out)
		}
	}
}

func equalSpecs(a, b []ModelSpec) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
