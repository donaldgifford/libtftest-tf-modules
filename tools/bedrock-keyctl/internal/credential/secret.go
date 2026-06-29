// Package credential defines the opaque SecretValue type that carries a
// Bedrock service-specific credential's one-time secret (the bearer
// token Claude Code reads via AWS_BEARER_TOKEN_BEDROCK).
//
// SecretValue is opaque by design: its String, GoString, and
// MarshalJSON methods all redact, so a SecretValue (or any struct
// embedding one) is safe to log or print. The raw value is reachable
// only through Reveal, which requires the unexported sink token —
// a forcing function that makes any access visible in code review and
// confines it to the secret-sink implementation. This enforces the
// secret-never-logged invariant from DESIGN-0009 §1 / RFC-0003
// structurally rather than by discipline.
package credential

import "encoding/json"

const redacted = "[REDACTED]"

// SecretValue holds a credential secret without exposing it to logging,
// printing, or general JSON serialization.
type SecretValue struct {
	v string
}

// NewSecretValue wraps a raw secret string returned by the AWS IAM API.
// It is called exactly once, where the credential is created.
func NewSecretValue(raw string) SecretValue {
	return SecretValue{v: raw}
}

// String always returns a fixed redaction mask so SecretValue is safe
// to pass to fmt verbs (%s, %v) and structured loggers.
func (s SecretValue) String() string {
	return redacted
}

// GoString redacts for the %#v verb.
func (s SecretValue) GoString() string {
	return "credential.SecretValue{v:" + redacted + "}"
}

// MarshalJSON redacts so a SecretValue never leaks through
// general-purpose JSON serialization.
func (s SecretValue) MarshalJSON() ([]byte, error) {
	return json.Marshal(redacted)
}

// IsZero reports whether the secret is empty (no value captured).
func (s SecretValue) IsZero() bool {
	return s.v == ""
}

// sinkToken is an unexported witness type. Only the credential package
// can construct one, and it hands the single value out via SinkToken,
// so a caller of Reveal must explicitly reference credential.SinkToken
// — visible and intentional in review.
type sinkToken struct{}

// SinkToken is the witness required to call Reveal. It exists so secret
// access is confined to sink implementations and obvious in code review.
var SinkToken = sinkToken{} //nolint:gochecknoglobals // intentional access witness, see package doc

// Reveal returns the raw secret. It requires SinkToken, signalling that
// only a secret-sink writer should call it. This is a code-review
// forcing function, not cryptographic access control.
func (s SecretValue) Reveal(_ sinkToken) string {
	return s.v
}
