package awsapi

import "context"

// MockMarketplaceClient is a recording MarketplaceClient for tests.
type MockMarketplaceClient struct {
	Calls []string

	// Subscribed is what IsSubscribed reports (idempotency pre-check).
	Subscribed bool
	// IsSubscribedErr fails the pre-check.
	IsSubscribedErr error
	// SubscribeErr drives the explicit-subscribe branch: nil (enabled),
	// ErrSubscribeUnsupported (fall back to invocation),
	// ErrAlreadySubscribed (no-action), or a hard error (failed).
	SubscribeErr error

	IsSubscribedCount int
	SubscribeCount    int
}

var _ MarketplaceClient = (*MockMarketplaceClient)(nil)

func (m *MockMarketplaceClient) IsSubscribed(_ context.Context, modelID string) (bool, error) {
	m.Calls = append(m.Calls, "IsSubscribed:"+modelID)
	m.IsSubscribedCount++
	if m.IsSubscribedErr != nil {
		return false, m.IsSubscribedErr
	}
	return m.Subscribed, nil
}

func (m *MockMarketplaceClient) Subscribe(_ context.Context, modelID string) error {
	m.Calls = append(m.Calls, "Subscribe:"+modelID)
	m.SubscribeCount++
	return m.SubscribeErr
}
