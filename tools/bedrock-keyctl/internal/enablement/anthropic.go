package enablement

import (
	"context"
	"errors"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
)

// anthropicUseCaseForm is the default Anthropic use-case form payload.
// The wire schema for PutUseCaseForModelAccess is SDK-/account-defined
// and not publicly pinned at v1 ship time (DESIGN-0009 §3 Path A), so
// this is a sensible default describing internal Claude Code usage.
// Operators override it via --use-case-payload @file.json in v1.1.
var anthropicUseCaseForm = []byte(`{` +
	`"companyName":"internal",` +
	`"useCaseDescription":"Internal developer tooling: Claude Code on Amazon Bedrock for software-engineering assistance.",` +
	`"intendedUsers":"internal-employees"` +
	`}`)

// EnableAnthropic submits the one-time Anthropic use-case form for
// modelID via PutUseCaseForModelAccess (Path A). It is idempotent: an
// already-submitted form (awsapi.ErrUseCaseAlreadyExists) yields
// OutcomeNoActionNeeded rather than an error.
func EnableAnthropic(ctx context.Context, bc awsapi.BedrockClient, modelID string) Result {
	r := Result{Model: modelID, Provider: "anthropic", Action: "use-case-form"}

	err := bc.PutUseCaseForModelAccess(ctx, anthropicUseCaseForm)
	switch {
	case err == nil:
		r.Outcome = OutcomeEnabled
	case errors.Is(err, awsapi.ErrUseCaseAlreadyExists):
		r.Outcome = OutcomeNoActionNeeded
	default:
		r.Outcome = OutcomeFailed
		r.Err = err
	}
	return r
}
