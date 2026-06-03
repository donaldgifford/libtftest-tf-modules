package awsapi

import "context"

// MarketplaceClient checks and ensures AWS Marketplace subscriptions for
// third-party Bedrock providers (enable-models Path C). The AWS SDK has
// no first-class "subscribe" call for Bedrock catalog entries, so the
// concrete implementation — explicit subscribe vs. first-invocation
// trigger, plus a ListEntities-backed idempotency check — lands in
// Phase 17 once DESIGN-0009 Q8's mechanism is pinned. Defined here so
// the enablement dispatch can depend on the interface from Phase 16.
type MarketplaceClient interface {
	// IsSubscribed reports whether the account is already subscribed to
	// the model's Marketplace listing (idempotency check).
	IsSubscribed(ctx context.Context, modelID string) (bool, error)
	// Subscribe ensures the principal is subscribed to the model's
	// Marketplace listing.
	Subscribe(ctx context.Context, modelID string) error
}
