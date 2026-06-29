package sink

import (
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
)

// Sink URI schemes.
const (
	schemeSM    = "sm://"
	schemeVault = "vault://"
)

// ParseURI resolves a sink URI to a Sink and the key (secret name)
// within it. v1 supports sm://<secret-name> only. vault:// is rejected
// with the deferral message (DESIGN-0009 Q7 resolution (c)); the Sink
// interface stays generic so the Vault implementation lands in v1.1
// without a rewrite.
func ParseURI(uri string, cfg *aws.Config) (Sink, string, error) {
	switch {
	case strings.HasPrefix(uri, schemeSM):
		name := strings.TrimPrefix(uri, schemeSM)
		if name == "" {
			return nil, "", fmt.Errorf("sink URI %q has an empty secret name (want sm://<secret-name>)", uri)
		}
		return NewSecretsManagerSink(cfg), name, nil

	case strings.HasPrefix(uri, schemeVault):
		return nil, "", fmt.Errorf("vault sink not yet implemented (deferred to v1.1); use sm://<secret-name>")

	default:
		return nil, "", fmt.Errorf("unsupported sink URI %q: only sm://<secret-name> is supported in v1", uri)
	}
}
