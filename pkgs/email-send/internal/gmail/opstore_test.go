package gmail

import (
	"errors"
	"strings"
	"testing"
)

func TestOperationStoreLifecycle(t *testing.T) {
	store := &OperationStore{Dir: t.TempDir()}

	// First reservation succeeds.
	prev, err := store.Reserve("op-1")
	if err != nil || prev != nil {
		t.Fatalf("first Reserve: prev=%v err=%v", prev, err)
	}

	// Concurrent/duplicate reservation while unresolved must fail closed.
	if _, err := store.Reserve("op-1"); err == nil || !strings.Contains(err.Error(), "unresolved") {
		t.Fatalf("expected unresolved error on concurrent Reserve, got %v", err)
	}

	// Transition to dispatching -> uncertain must still refuse retry.
	if err := store.Transition("op-1", "dispatching", nil, nil); err != nil {
		t.Fatalf("Transition(dispatching): %v", err)
	}
	if err := store.Transition("op-1", "uncertain", nil, errors.New("timeout waiting for Sent")); err != nil {
		t.Fatalf("Transition(uncertain): %v", err)
	}
	if _, err := store.Reserve("op-1"); err == nil || !strings.Contains(err.Error(), "status=uncertain") {
		t.Fatalf("expected uncertain refusal on Reserve, got %v", err)
	}

	// Completed send returns idempotent replay without resending.
	want := &Receipt{Status: "sent", OperationID: "op-2", Subject: "Hi", VerifiedInSent: true}
	if _, err := store.Reserve("op-2"); err != nil {
		t.Fatalf("Reserve(op-2): %v", err)
	}
	if err := store.Transition("op-2", "sent", want, nil); err != nil {
		t.Fatalf("Transition(sent): %v", err)
	}
	got, err := store.Reserve("op-2")
	if err != nil || got == nil || got.Subject != "Hi" || got.Status != "sent" {
		t.Fatalf("expected idempotent replay, got receipt=%+v err=%v", got, err)
	}

	// Pre-send failure releases reservation cleanly.
	if _, err := store.Reserve("op-3"); err != nil {
		t.Fatalf("Reserve(op-3): %v", err)
	}
	store.ReleasePreSend("op-3")
	if _, err := store.Reserve("op-3"); err != nil {
		t.Fatalf("Reserve(op-3) after ReleasePreSend should succeed, got %v", err)
	}
}
