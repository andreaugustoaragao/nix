package gmail

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// OperationStore provides atomic reservation and crash-safe state transitions for --operation IDs.
// States:
//   - "reserved":    acquired atomically before browser launch (pre-click)
//   - "dispatching": persisted immediately before clicking Gmail Send
//   - "uncertain":   click was attempted, but post-click confirmation/Sent check failed or timed out
//   - "sent":        verified delivered in Gmail Sent
type OperationStore struct {
	Dir string
}

type OperationRecord struct {
	OperationID string   `json:"operation_id"`
	Status      string   `json:"status"`
	UpdatedUTC  string   `json:"updated_utc"`
	Error       string   `json:"error,omitempty"`
	Receipt     *Receipt `json:"receipt,omitempty"`
}

func (s *OperationStore) path(opID string) string {
	return filepath.Join(s.Dir, opID+".json")
}

// Reserve atomically claims opID with O_CREATE|O_EXCL before any send attempt.
// Returns (existingSentReceipt, nil) on idempotent replay of a completed send,
// or an error refusing retry if an unresolved reservation/dispatch/uncertain record already exists.
func (s *OperationStore) Reserve(opID string) (*Receipt, error) {
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return nil, fmt.Errorf("create operation state dir %s: %w", s.Dir, err)
	}
	p := s.path(opID)
	rec := OperationRecord{
		OperationID: opID,
		Status:      "reserved",
		UpdatedUTC:  time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return nil, err
	}
	data = append(data, '\n')

	f, err := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err == nil {
		_, werr := f.Write(data)
		cerr := f.Close()
		if werr != nil {
			_ = os.Remove(p)
			return nil, fmt.Errorf("write reservation %s: %w", p, werr)
		}
		if cerr != nil {
			_ = os.Remove(p)
			return nil, fmt.Errorf("close reservation %s: %w", p, cerr)
		}
		return nil, nil
	}
	if !errors.Is(err, os.ErrExist) {
		return nil, fmt.Errorf("reserve operation %s: %w", opID, err)
	}

	// Reservation already exists: read current status and NEVER blindly retry.
	raw, rerr := os.ReadFile(p)
	if rerr != nil {
		return nil, fmt.Errorf("operation %q already reserved (%s) but unreadable: %w", opID, p, rerr)
	}
	var existing OperationRecord
	if uerr := json.Unmarshal(raw, &existing); uerr == nil && existing.Status != "" {
		if existing.Status == "sent" && existing.Receipt != nil {
			return existing.Receipt, nil
		}
		return nil, fmt.Errorf("operation %q is unresolved (status=%s, updated=%s, path=%s); verify Gmail Sent manually instead of retrying this operation ID",
			opID, existing.Status, existing.UpdatedUTC, p)
	}
	// Backwards-compatibility: check if file contains a raw Receipt directly.
	var legacy Receipt
	if uerr := json.Unmarshal(raw, &legacy); uerr == nil && legacy.Status == "sent" {
		return &legacy, nil
	}
	return nil, fmt.Errorf("operation %q already exists at %s in unknown state; refusing to resend", opID, p)
}

// Transition atomically replaces the operation record via temp-file + fsync + rename.
func (s *OperationStore) Transition(opID, status string, receipt *Receipt, opErr error) error {
	rec := OperationRecord{
		OperationID: opID,
		Status:      status,
		UpdatedUTC:  time.Now().UTC().Format(time.RFC3339),
		Receipt:     receipt,
	}
	if opErr != nil {
		rec.Error = opErr.Error()
	}
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	tmp, err := os.CreateTemp(s.Dir, opID+".*.tmp")
	if err != nil {
		return fmt.Errorf("create temp operation file: %w", err)
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, s.path(opID)); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("commit operation state %s: %w", status, err)
	}
	return nil
}

// ReleasePreSend removes an un-dispatched reservation when validation/compose failed BEFORE Send was clicked.
func (s *OperationStore) ReleasePreSend(opID string) {
	_ = os.Remove(s.path(opID))
}
