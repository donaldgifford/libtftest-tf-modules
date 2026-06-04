package sink

import (
	"context"
	"errors"
	"testing"
)

func TestMockSink_RoundTripAndCalls(t *testing.T) {
	t.Parallel()

	m := NewMockSink()
	ctx := context.Background()

	if err := m.Write(ctx, "k", []byte("v")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	got, err := m.Read(ctx, "k")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if string(got) != "v" {
		t.Errorf("Read = %q, want v", got)
	}
	if err := m.Delete(ctx, "k"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok := m.Store["k"]; ok {
		t.Error("key still present after Delete")
	}

	want := []string{"Write:k", "Read:k", "Delete:k"}
	if len(m.Calls) != len(want) {
		t.Fatalf("calls = %v, want %v", m.Calls, want)
	}
	for i := range want {
		if m.Calls[i] != want[i] {
			t.Errorf("call[%d] = %q, want %q", i, m.Calls[i], want[i])
		}
	}
}

func TestMockSink_ErrorInjection(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	boom := errors.New("boom")

	m := NewMockSink()
	m.WriteErr = boom
	if err := m.Write(ctx, "k", []byte("v")); !errors.Is(err, boom) {
		t.Errorf("Write err = %v, want boom", err)
	}

	m = NewMockSink()
	m.ReadErr = boom
	if _, err := m.Read(ctx, "k"); !errors.Is(err, boom) {
		t.Errorf("Read err = %v, want boom", err)
	}

	m = NewMockSink()
	m.DeleteErr = boom
	if err := m.Delete(ctx, "k"); !errors.Is(err, boom) {
		t.Errorf("Delete err = %v, want boom", err)
	}
}
