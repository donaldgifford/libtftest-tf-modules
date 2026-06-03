package enablement

import "context"

// EnableAmazon is the Path B no-op: Amazon-owned models (the Nova
// family) are auto-enabled in all commercial regions with no use-case
// form and no Marketplace subscribe, so there is nothing to do. The ctx
// is accepted for dispatch symmetry but unused. See DESIGN-0009 §3
// Path B.
func EnableAmazon(_ context.Context, modelID string) Result {
	return Result{
		Model:    modelID,
		Provider: "amazon",
		Action:   "none",
		Outcome:  OutcomeNoActionNeeded,
	}
}
