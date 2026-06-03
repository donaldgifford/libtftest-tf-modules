package sink

import (
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
)

func TestParseURI(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		uri         string
		wantKey     string
		wantErr     bool
		errContains string
	}{
		{
			name:    "sm scheme returns secret name",
			uri:     "sm://bedrock/claude-code/platform",
			wantKey: "bedrock/claude-code/platform",
		},
		{
			name:    "sm scheme simple name",
			uri:     "sm://my-secret",
			wantKey: "my-secret",
		},
		{
			name:        "sm scheme empty name rejected",
			uri:         "sm://",
			wantErr:     true,
			errContains: "empty secret name",
		},
		{
			name:        "vault scheme deferred to v1.1",
			uri:         "vault://secret/claude-code/bedrock/acct/user",
			wantErr:     true,
			errContains: "v1.1",
		},
		{
			name:        "vault scheme message points to sm",
			uri:         "vault://x",
			wantErr:     true,
			errContains: "sm://",
		},
		{
			name:        "unknown scheme rejected",
			uri:         "https://example.com/secret",
			wantErr:     true,
			errContains: "only sm://",
		},
		{
			name:        "empty uri rejected",
			uri:         "",
			wantErr:     true,
			errContains: "only sm://",
		},
	}

	cfg := &aws.Config{}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			s, key, err := ParseURI(tt.uri, cfg)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("ParseURI(%q) = nil error, want error", tt.uri)
				}
				if !strings.Contains(err.Error(), tt.errContains) {
					t.Errorf("ParseURI(%q) error = %q, want substring %q", tt.uri, err, tt.errContains)
				}
				if s != nil {
					t.Errorf("ParseURI(%q) returned non-nil sink on error", tt.uri)
				}
				return
			}

			if err != nil {
				t.Fatalf("ParseURI(%q) unexpected error: %v", tt.uri, err)
			}
			if key != tt.wantKey {
				t.Errorf("ParseURI(%q) key = %q, want %q", tt.uri, key, tt.wantKey)
			}
			if s == nil {
				t.Errorf("ParseURI(%q) returned nil sink on success", tt.uri)
			}
		})
	}
}
