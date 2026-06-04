// Package sink defines the secret-sink abstraction bedrock-keyctl
// writes minted credentials to. The credential's one-time secret never
// touches Terraform state or stdout — it flows only into a Sink.
//
// The Sink interface is intentionally a generic key/bytes store so a
// second backend (HashiCorp Vault, deferred to v1.1 per DESIGN-0009 Q7)
// lands as a new implementation, not a rewrite. The AWS Secrets Manager
// implementation and the credential-envelope helpers that keep the raw
// secret confined to this package land in Phase 12.
package sink

import "context"

// Sink is a generic secret store keyed by name.
type Sink interface {
	// Write stores payload under key, creating or overwriting it.
	Write(ctx context.Context, key string, payload []byte) error
	// Read returns the payload stored under key.
	Read(ctx context.Context, key string) ([]byte, error)
	// Delete removes the secret stored under key.
	Delete(ctx context.Context, key string) error
}
