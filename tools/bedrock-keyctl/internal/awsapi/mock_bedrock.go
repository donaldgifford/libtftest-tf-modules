package awsapi

import "context"

// MockBedrockClient is a recording BedrockClient for tests. Each method
// records its call and returns the matching injected error, so tests can
// drive the rotate verify step and the enablement Path A/C branches.
type MockBedrockClient struct {
	Calls []string

	// GetInferenceProfileErr fails the rotate verification step.
	GetInferenceProfileErr error
	// PutUseCaseErr drives Path A: nil (enabled), ErrUseCaseAlreadyExists
	// (no-action), or a hard error (failed).
	PutUseCaseErr error
	// InvokeErr drives the Path C invocation trigger: nil (enabled),
	// ErrAlreadySubscribed / ErrModelInputRejected, or a hard error.
	InvokeErr error

	GetInferenceProfileCount int
	PutUseCaseCount          int
	InvokeCount              int
}

var _ BedrockClient = (*MockBedrockClient)(nil)

func (m *MockBedrockClient) GetInferenceProfile(_ context.Context, profileID string) error {
	m.Calls = append(m.Calls, "GetInferenceProfile:"+profileID)
	m.GetInferenceProfileCount++
	return m.GetInferenceProfileErr
}

func (m *MockBedrockClient) PutUseCaseForModelAccess(_ context.Context, _ []byte) error {
	m.Calls = append(m.Calls, "PutUseCaseForModelAccess")
	m.PutUseCaseCount++
	return m.PutUseCaseErr
}

func (m *MockBedrockClient) InvokeModel(_ context.Context, modelID string, _ []byte) error {
	m.Calls = append(m.Calls, "InvokeModel:"+modelID)
	m.InvokeCount++
	return m.InvokeErr
}
