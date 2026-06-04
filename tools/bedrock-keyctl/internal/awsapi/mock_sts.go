package awsapi

import "context"

// MockSTSClient is a recording STSClient for the targeting tests. It
// returns a fixed account ID and records each AssumeRole's role ARN so
// tests can assert the per-target-mode call counts.
type MockSTSClient struct {
	// Account is returned by CallerAccountID.
	Account string
	// Creds is returned by AssumeRole.
	Creds AssumedCredentials

	// AssumeRoleARNs records each AssumeRole call's role ARN in order.
	AssumeRoleARNs []string

	CallerErr error
	AssumeErr error
}

var _ STSClient = (*MockSTSClient)(nil)

func (m *MockSTSClient) CallerAccountID(_ context.Context) (string, error) {
	if m.CallerErr != nil {
		return "", m.CallerErr
	}
	return m.Account, nil
}

func (m *MockSTSClient) AssumeRole(_ context.Context, roleARN, _ string) (AssumedCredentials, error) {
	m.AssumeRoleARNs = append(m.AssumeRoleARNs, roleARN)
	if m.AssumeErr != nil {
		return AssumedCredentials{}, m.AssumeErr
	}
	return m.Creds, nil
}
