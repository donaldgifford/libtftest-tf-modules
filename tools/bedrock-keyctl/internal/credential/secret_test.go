package credential

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

const rawSecret = "bedrock-bearer-token-SUPER-SECRET-0123456789abcdef"

// fmtVerb formats v with a runtime-supplied verb, so static analysis
// can't rewrite a literal "%s"/"%v" into a direct String() call.
func fmtVerb(verb string, v any) string {
	return fmt.Sprintf(verb, v)
}

func TestSecretValue_RedactsEverywhere(t *testing.T) {
	t.Parallel()

	s := NewSecretValue(rawSecret)

	// The fmt verbs are the realistic leak path (e.g.
	// log.Printf("%s", secret)). The verb is held in a variable so the
	// linters don't fold "%s"/"%v" into a direct String() call — the
	// point is to prove the verb path itself redacts.
	checks := map[string]string{
		"String":      s.String(),
		"GoString":    s.GoString(),
		"struct-wrap": fmtVerb("%v", struct{ Secret SecretValue }{s}),
	}
	for _, verb := range []string{"%s", "%v", "%+v", "%#v"} {
		checks[verb] = fmtVerb(verb, s)
	}

	for name, got := range checks {
		if strings.Contains(got, rawSecret) {
			t.Errorf("%s leaked the raw secret: %q", name, got)
		}
		if !strings.Contains(got, redacted) {
			t.Errorf("%s = %q, want it to contain %q", name, got, redacted)
		}
	}
}

func TestSecretValue_MarshalJSONRedacts(t *testing.T) {
	t.Parallel()

	s := NewSecretValue(rawSecret)

	// Direct marshal.
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if strings.Contains(string(b), rawSecret) {
		t.Errorf("MarshalJSON leaked the secret: %s", b)
	}

	// Marshal while embedded in a struct (the realistic leak path).
	b, err = json.Marshal(struct {
		Key SecretValue `json:"key"`
	}{s})
	if err != nil {
		t.Fatalf("Marshal struct: %v", err)
	}
	if strings.Contains(string(b), rawSecret) {
		t.Errorf("embedded MarshalJSON leaked the secret: %s", b)
	}
}

func TestSecretValue_RevealReturnsRaw(t *testing.T) {
	t.Parallel()

	s := NewSecretValue(rawSecret)
	if got := s.Reveal(SinkToken); got != rawSecret {
		t.Errorf("Reveal = %q, want the raw secret", got)
	}
}

func TestSecretValue_IsZero(t *testing.T) {
	t.Parallel()

	if !NewSecretValue("").IsZero() {
		t.Error("empty secret should be zero")
	}
	if NewSecretValue("x").IsZero() {
		t.Error("non-empty secret should not be zero")
	}
}
