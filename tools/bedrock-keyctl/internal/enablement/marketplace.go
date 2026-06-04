package enablement

import (
	"context"
	"errors"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
)

// SubscribePath selects how Path C enables a third-party Marketplace
// model (DESIGN-0009 §3 Path C, Q8).
type SubscribePath string

const (
	// SubscribeAuto tries an explicit subscribe and falls back to the
	// invocation trigger if the API can't subscribe out of listing
	// context. The default.
	SubscribeAuto SubscribePath = "auto"
	// SubscribeExplicit only attempts an explicit Marketplace subscribe.
	SubscribeExplicit SubscribePath = "explicit"
	// SubscribeInvocation only fires the no-op invocation trigger.
	SubscribeInvocation SubscribePath = "invocation"
)

// ValidSubscribePath reports whether p is a recognised sub-path.
func ValidSubscribePath(p SubscribePath) bool {
	switch p {
	case SubscribeAuto, SubscribeExplicit, SubscribeInvocation:
		return true
	default:
		return false
	}
}

// actionAlreadySubscribed is the result-table action for an
// already-subscribed (idempotent) Marketplace listing.
const actionAlreadySubscribed = "marketplace-subscribe (already subscribed)"

// triggerBody is the minimal InvokeModel payload used to fire the
// Marketplace auto-subscribe. The body is provider-generic, so for some
// providers the model rejects it at input validation — which the awsapi
// layer reports as ErrModelInputRejected and Path C treats as proof of
// access (the call passed the subscribe gate). v1 accepts the ~1-token
// cost of a successful trigger; see DESIGN-0009 §3 Path C.
var triggerBody = []byte(`{"prompt":" ","max_tokens":1}`)

// EnableMarketplace enables a third-party Marketplace model (Path C).
// For SubscribeAuto it tries an explicit subscribe first and falls back
// to the invocation trigger when the explicit path is unsupported. It is
// idempotent: an already-subscribed listing yields OutcomeNoActionNeeded.
func EnableMarketplace(ctx context.Context, mkt awsapi.MarketplaceClient, bc awsapi.BedrockClient, spec ModelSpec, path SubscribePath) Result {
	r := Result{Model: spec.ModelID, Provider: spec.Provider, Action: "marketplace-subscribe"}

	if subscribed, err := mkt.IsSubscribed(ctx, spec.ModelID); err == nil && subscribed {
		r.Action = actionAlreadySubscribed
		r.Outcome = OutcomeNoActionNeeded
		return r
	}

	switch path {
	case SubscribeExplicit:
		classifySubscribe(&r, "explicit", mkt.Subscribe(ctx, spec.ModelID))
	case SubscribeInvocation:
		classifyInvocation(&r, bc.InvokeModel(ctx, spec.ModelID, triggerBody))
	case SubscribeAuto:
		enableMarketplaceAuto(ctx, mkt, bc, spec, &r)
	default:
		r.Outcome = OutcomeFailed
		r.Err = errors.New("invalid marketplace subscribe path " + string(path))
	}
	return r
}

// enableMarketplaceAuto tries explicit subscribe, then falls back to the
// invocation trigger when explicit subscribe is unsupported.
func enableMarketplaceAuto(ctx context.Context, mkt awsapi.MarketplaceClient, bc awsapi.BedrockClient, spec ModelSpec, r *Result) {
	err := mkt.Subscribe(ctx, spec.ModelID)
	switch {
	case err == nil:
		r.Action = "marketplace-subscribe (explicit)"
		r.Outcome = OutcomeEnabled
	case errors.Is(err, awsapi.ErrAlreadySubscribed):
		r.Action = actionAlreadySubscribed
		r.Outcome = OutcomeNoActionNeeded
	case errors.Is(err, awsapi.ErrSubscribeUnsupported):
		classifyInvocation(r, bc.InvokeModel(ctx, spec.ModelID, triggerBody))
	default:
		r.Outcome = OutcomeFailed
		r.Err = err
	}
}

// classifySubscribe maps an explicit-subscribe error onto r.
func classifySubscribe(r *Result, label string, err error) {
	switch {
	case err == nil:
		r.Action = "marketplace-subscribe (" + label + ")"
		r.Outcome = OutcomeEnabled
	case errors.Is(err, awsapi.ErrAlreadySubscribed):
		r.Action = actionAlreadySubscribed
		r.Outcome = OutcomeNoActionNeeded
	default:
		r.Outcome = OutcomeFailed
		r.Err = err
	}
}

// classifyInvocation maps an invocation-trigger error onto r. A rejected
// input body means access is granted (the call passed the subscribe
// gate), so it counts as enabled.
func classifyInvocation(r *Result, err error) {
	switch {
	case err == nil:
		r.Action = "marketplace-subscribe (invocation)"
		r.Outcome = OutcomeEnabled
	case errors.Is(err, awsapi.ErrModelInputRejected):
		r.Action = "marketplace-subscribe (invocation; access confirmed)"
		r.Outcome = OutcomeEnabled
	case errors.Is(err, awsapi.ErrAlreadySubscribed):
		r.Action = actionAlreadySubscribed
		r.Outcome = OutcomeNoActionNeeded
	default:
		r.Outcome = OutcomeFailed
		r.Err = err
	}
}
