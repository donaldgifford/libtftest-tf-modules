package awsapi

import (
	"context"
	"fmt"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/credential"
)

// MockIAMClient is an in-memory IAMClient for tests. It records every
// call in Calls (for sequence assertions) and keeps credential state so
// tests can inspect which credentials remain Active after an operation.
type MockIAMClient struct {
	// Calls records each method call as "Method:arg" for ordered
	// sequence assertions (e.g. the rotate zero-downtime contract).
	Calls []string

	// CreateErr, ListErr, SetStatusErr, DeleteErr inject method errors.
	CreateErr    error
	ListErr      error
	SetStatusErr error
	DeleteErr    error

	// NextSecret is the secret returned by the next CreateCredential.
	NextSecret string

	creds map[string]*Credential
	idSeq int
}

var _ IAMClient = (*MockIAMClient)(nil)

// NewMockIAMClient returns an empty mock.
func NewMockIAMClient() *MockIAMClient {
	return &MockIAMClient{creds: make(map[string]*Credential)}
}

// Seed inserts a pre-existing credential (e.g. the active "old" key a
// rotate or revoke acts on).
func (m *MockIAMClient) Seed(c Credential) {
	if m.creds == nil {
		m.creds = make(map[string]*Credential)
	}
	cp := c
	m.creds[c.ID] = &cp
}

// Status reports a credential's current status, or "" if it was deleted.
func (m *MockIAMClient) Status(id string) string {
	if c, ok := m.creds[id]; ok {
		return c.Status
	}
	return ""
}

// Exists reports whether a credential is still present (not deleted).
func (m *MockIAMClient) Exists(id string) bool {
	_, ok := m.creds[id]
	return ok
}

func (m *MockIAMClient) CreateCredential(_ context.Context, userName string, _ int32) (CreatedCredential, error) {
	m.Calls = append(m.Calls, "Create:"+userName)
	if m.CreateErr != nil {
		return CreatedCredential{}, m.CreateErr
	}

	m.idSeq++
	id := fmt.Sprintf("AKIAMOCK%04d", m.idSeq)
	c := Credential{ID: id, UserName: userName, Status: StatusActive}
	if m.creds == nil {
		m.creds = make(map[string]*Credential)
	}
	cp := c
	m.creds[id] = &cp

	return CreatedCredential{
		Credential: c,
		Secret:     credential.NewSecretValue(m.NextSecret),
	}, nil
}

func (m *MockIAMClient) ListCredentials(_ context.Context, userName string) ([]Credential, error) {
	m.Calls = append(m.Calls, "List:"+userName)
	if m.ListErr != nil {
		return nil, m.ListErr
	}

	out := make([]Credential, 0, len(m.creds))
	for _, c := range m.creds {
		if c.UserName == userName || userName == "" {
			out = append(out, *c)
		}
	}
	return out, nil
}

func (m *MockIAMClient) SetCredentialStatus(_ context.Context, _, credentialID, status string) error {
	m.Calls = append(m.Calls, "SetStatus:"+credentialID+"="+status)
	if m.SetStatusErr != nil {
		return m.SetStatusErr
	}
	if c, ok := m.creds[credentialID]; ok {
		c.Status = status
	}
	return nil
}

func (m *MockIAMClient) DeleteCredential(_ context.Context, _, credentialID string) error {
	m.Calls = append(m.Calls, "Delete:"+credentialID)
	if m.DeleteErr != nil {
		return m.DeleteErr
	}
	delete(m.creds, credentialID)
	return nil
}
