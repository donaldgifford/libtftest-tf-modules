package sink

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/credential"
)

// Envelope is the JSON payload bedrock-keyctl stores in a sink
// (DESIGN-0009 Q5). The consumer (Claude Code via
// AWS_BEARER_TOKEN_BEDROCK) reads only bedrock_api_key; credential_id
// and expires_at co-locate the rotation metadata so rotate needs no
// parallel state store.
type Envelope struct {
	BedrockAPIKey string    `json:"bedrock_api_key"`
	CredentialID  string    `json:"credential_id"`
	ExpiresAt     time.Time `json:"expires_at"`
}

// WriteCredential builds the envelope and writes it to the sink. The raw
// secret is revealed here — at the sink boundary, the one place
// authorized to call SecretValue.Reveal — and never returned to callers,
// keeping it out of cmd/ entirely.
func WriteCredential(ctx context.Context, s Sink, key, credID string, secret credential.SecretValue, expiresAt time.Time) error {
	env := Envelope{
		BedrockAPIKey: secret.Reveal(credential.SinkToken),
		CredentialID:  credID,
		ExpiresAt:     expiresAt,
	}

	payload, err := json.Marshal(env)
	if err != nil {
		return fmt.Errorf("marshal credential envelope: %w", err)
	}

	if err := s.Write(ctx, key, payload); err != nil {
		return fmt.Errorf("write credential envelope: %w", err)
	}
	return nil
}

// ReadCredential reads and parses the stored envelope. Used by rotate to
// recover the credential ID and by operators verifying a sink's
// contents. The returned Envelope carries the bearer token in plaintext;
// callers must not log it.
func ReadCredential(ctx context.Context, s Sink, key string) (Envelope, error) {
	payload, err := s.Read(ctx, key)
	if err != nil {
		return Envelope{}, fmt.Errorf("read credential envelope: %w", err)
	}

	var env Envelope
	if err := json.Unmarshal(payload, &env); err != nil {
		return Envelope{}, fmt.Errorf("unmarshal credential envelope: %w", err)
	}
	return env, nil
}
