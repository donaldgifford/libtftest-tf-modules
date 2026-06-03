package awsapi

import (
	"context"
	"errors"

	"github.com/aws/aws-sdk-go-v2/aws"
)

// ErrSubscribeUnsupported signals that AWS exposes no callable subscribe
// API for Bedrock Marketplace catalog entries, so the explicit-subscribe
// sub-path cannot run. Path C's `auto` mode treats this as the trigger
// to fall back to a no-op invocation (DESIGN-0009 §3 Path C, Q8).
var ErrSubscribeUnsupported = errors.New("explicit Marketplace subscribe is not available for Bedrock catalog entries; use the invocation trigger")

// MarketplaceClient checks and ensures AWS Marketplace subscriptions for
// third-party Bedrock providers (enable-models Path C). The AWS SDK has
// no first-class "subscribe" call for Bedrock catalog entries (the first
// model invocation auto-subscribes a principal holding
// aws-marketplace:Subscribe), so the v1 implementation reports
// not-subscribed and routes real enablement through the invocation
// trigger. The interface stays the contract so a future explicit
// subscribe (or an entitlement-backed IsSubscribed) is a drop-in.
type MarketplaceClient interface {
	// IsSubscribed reports whether the account is already subscribed to
	// the model's Marketplace listing (idempotency check).
	IsSubscribed(ctx context.Context, modelID string) (bool, error)
	// Subscribe ensures the principal is subscribed to the model's
	// Marketplace listing.
	Subscribe(ctx context.Context, modelID string) error
}

// marketplaceClient is the v1 MarketplaceClient. It holds no SDK client
// today: Bedrock model subscription is governed by IAM and auto-triggered
// on first invocation, not by a callable Marketplace API. The struct
// exists so the contract has a concrete production binding and a future
// entitlement/catalog-backed implementation slots in here.
type marketplaceClient struct{}

var _ MarketplaceClient = (*marketplaceClient)(nil)

// NewMarketplaceClient builds the v1 MarketplaceClient. cfg is accepted
// for forward compatibility (a future entitlement-backed check needs it)
// but unused today.
func NewMarketplaceClient(_ *aws.Config) MarketplaceClient {
	return &marketplaceClient{}
}

// IsSubscribed is best-effort in v1: Bedrock catalog product codes are
// not reliably resolvable from a model ID, so it reports not-subscribed
// and lets the idempotent invocation trigger handle the actual state.
func (c *marketplaceClient) IsSubscribed(_ context.Context, _ string) (bool, error) {
	return false, nil
}

// Subscribe returns ErrSubscribeUnsupported: there is no callable
// subscribe API for Bedrock catalog entries. The enablement layer falls
// back to the invocation trigger.
func (c *marketplaceClient) Subscribe(_ context.Context, _ string) error {
	return ErrSubscribeUnsupported
}
