package sink

import "context"

// MockSink is an in-memory Sink for tests. It records each call in Calls
// and stores written values so tests can assert sink contents and the
// IAM-before-sink ordering of revoke.
type MockSink struct {
	Store map[string][]byte
	Calls []string

	WriteErr  error
	ReadErr   error
	DeleteErr error
}

var _ Sink = (*MockSink)(nil)

// NewMockSink returns an empty in-memory sink.
func NewMockSink() *MockSink {
	return &MockSink{Store: make(map[string][]byte)}
}

func (m *MockSink) Write(_ context.Context, key string, value []byte) error {
	m.Calls = append(m.Calls, "Write:"+key)
	if m.WriteErr != nil {
		return m.WriteErr
	}
	if m.Store == nil {
		m.Store = make(map[string][]byte)
	}
	cp := make([]byte, len(value))
	copy(cp, value)
	m.Store[key] = cp
	return nil
}

func (m *MockSink) Read(_ context.Context, key string) ([]byte, error) {
	m.Calls = append(m.Calls, "Read:"+key)
	if m.ReadErr != nil {
		return nil, m.ReadErr
	}
	return m.Store[key], nil
}

func (m *MockSink) Delete(_ context.Context, key string) error {
	m.Calls = append(m.Calls, "Delete:"+key)
	if m.DeleteErr != nil {
		return m.DeleteErr
	}
	delete(m.Store, key)
	return nil
}
