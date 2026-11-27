package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"faragao.net/netwatch/internal/model"
)

const DefaultUrgentReminder = 24 * time.Hour

// Store provides atomic JSON persistence and concurrency-safe finding lifecycle operations.
type Store struct {
	mu   sync.Mutex
	path string
	data model.State
}

// ReconcileResult partitions evaluated findings into email delivery buckets without prematurely
// advancing notification timestamps before SMTP delivery succeeds.
type ReconcileResult struct {
	UrgentToSend     []model.TrackedFinding
	DailyCandidates  []model.TrackedFinding
	DigestCandidates []model.TrackedFinding
	ResolvedToSend   []model.TrackedFinding
}

// Load reads state from path, or initializes an empty store if the file does not yet exist.
func Load(path string) (*Store, error) {
	s := &Store{
		path: path,
		data: emptyState(),
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s, nil
		}
		return nil, fmt.Errorf("read state %s: %w", path, err)
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		return s, nil
	}
	var st model.State
	if err := json.Unmarshal(raw, &st); err != nil {
		return nil, fmt.Errorf("decode state %s: %w", path, err)
	}
	if st.FeedStatus == nil {
		st.FeedStatus = make(map[string]model.FeedStatus)
	}
	if st.Findings == nil {
		st.Findings = make(map[string]*model.TrackedFinding)
	}
	s.data = st
	return s, nil
}

func emptyState() model.State {
	return model.State{
		FeedStatus: make(map[string]model.FeedStatus),
		Findings:   make(map[string]*model.TrackedFinding),
	}
}

// Save atomically persists state to disk with mode 0600.
func (s *Store) Save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveLocked()
}

func (s *Store) saveLocked() error {
	if s.path == "" {
		return nil
	}
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	raw, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return fmt.Errorf("encode state: %w", err)
	}
	raw = append(raw, '\n')
	tmp, err := os.CreateTemp(dir, ".netwatch-state-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp state: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}
	if err := tmp.Chmod(0o600); err != nil {
		cleanup()
		return err
	}
	if _, err := tmp.Write(raw); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, s.path)
}

// SnapshotCopy returns a safe value copy of persisted state for read-only reporting.
func (s *Store) SnapshotCopy() model.State {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, err := json.Marshal(s.data)
	if err != nil {
		return s.data
	}
	var cp model.State
	_ = json.Unmarshal(raw, &cp)
	if cp.FeedStatus == nil {
		cp.FeedStatus = make(map[string]model.FeedStatus)
	}
	if cp.Findings == nil {
		cp.Findings = make(map[string]*model.TrackedFinding)
	}
	return cp
}

// RecordSnapshot persists the latest firewall snapshot and optional updated feed statuses.
func (s *Store) RecordSnapshot(snap *model.OPNsenseSnapshot, feeds map[string]model.FeedStatus, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if snap != nil {
		cp := *snap
		s.data.LatestSnapshot = &cp
	}
	if feeds != nil {
		s.data.FeedStatus = feeds
	}
	s.data.LastUpdated = now
	return s.saveLocked()
}

// RecordFeedStatuses persists refreshed external feed statuses.
func (s *Store) RecordFeedStatuses(feeds map[string]model.FeedStatus, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.FeedStatus = feeds
	s.data.LastUpdated = now
	return s.saveLocked()
}

// RecordHeartbeat saves the outcome of a Healthchecks.io ping attempt.
func (s *Store) RecordHeartbeat(ok bool, errMsg string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ok {
		s.data.LastHeartbeatOK = now
		s.data.LastHeartbeatErr = ""
	} else {
		s.data.LastHeartbeatErr = errMsg
	}
	s.data.LastUpdated = now
	return s.saveLocked()
}

// MarkDailySent records when the daily grouped security notice was emailed.
func (s *Store) MarkDailySent(now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.LastDailySent = now
	s.data.LastUpdated = now
	return s.saveLocked()
}

// MarkDigestSent records when the weekly digest was emailed.
func (s *Store) MarkDigestSent(now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.LastDigestSent = now
	s.data.LastUpdated = now
	return s.saveLocked()
}

// Reconcile merges active evaluated findings against tracked state, deduplicates notifications,
// enforces urgent reminder intervals, and resolves absent findings ONLY on a clean recheck.
func (s *Store) Reconcile(findings []model.Finding, cleanRecheck bool, now time.Time, urgentReminder time.Duration) (ReconcileResult, error) {
	if urgentReminder <= 0 {
		urgentReminder = DefaultUrgentReminder
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	var res ReconcileResult
	active := make(map[string]struct{}, len(findings))

	for _, f := range findings {
		if f.Synthetic {
			continue // synthetic tests stay isolated unless explicitly stored via TrackSynthetic
		}
		active[f.ID] = struct{}{}
		tf, exists := s.data.Findings[f.ID]
		if !exists || tf.Status == model.StatusResolved {
			tf = &model.TrackedFinding{
				Finding:      f,
				Status:       model.StatusOpen,
				LastSeverity: f.Severity,
			}
			tf.FirstSeen = now
			tf.LastSeen = now
			s.data.Findings[f.ID] = tf
		} else {
			prevFirst := tf.FirstSeen
			prevNotifiedCount := tf.NotifiedCount
			prevLastNotified := tf.LastNotified
			prevAckAt := tf.AcknowledgedAt
			prevAckNote := tf.AckNote
			prevStatus := tf.Status
			prevLastSev := tf.LastSeverity

			tf.Finding = f
			tf.FirstSeen = prevFirst
			tf.LastSeen = now
			tf.NotifiedCount = prevNotifiedCount
			tf.LastNotified = prevLastNotified
			tf.AcknowledgedAt = prevAckAt
			tf.AckNote = prevAckNote
			tf.Status = prevStatus
			tf.LastSeverity = prevLastSev
		}

		switch f.Severity {
		case model.SeverityUrgent:
			escalated := tf.LastSeverity != model.SeverityUrgent && tf.NotifiedCount > 0
			neverSent := tf.NotifiedCount == 0
			reminderDue := tf.Status == model.StatusOpen && !tf.LastNotified.IsZero() && now.Sub(tf.LastNotified) >= urgentReminder
			if neverSent || escalated || reminderDue {
				res.UrgentToSend = append(res.UrgentToSend, *tf)
			}
		case model.SeverityDaily:
			if tf.Status != model.StatusAcked {
				res.DailyCandidates = append(res.DailyCandidates, *tf)
			}
		case model.SeverityDigest:
			res.DigestCandidates = append(res.DigestCandidates, *tf)
		}
	}

	if cleanRecheck {
		var ids []string
		for id := range s.data.Findings {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		for _, id := range ids {
			tf := s.data.Findings[id]
			if tf.Synthetic {
				continue
			}
			if tf.Status != model.StatusOpen && tf.Status != model.StatusAcked {
				continue
			}
			if _, stillActive := active[id]; stillActive {
				continue
			}
			t := now
			tf.Status = model.StatusResolved
			tf.ResolvedAt = &t
			tf.LastSeen = now
			if tf.NotifiedCount > 0 {
				res.ResolvedToSend = append(res.ResolvedToSend, *tf)
			}
		}
	}

	s.data.LastUpdated = now
	return res, s.saveLocked()
}

// MarkSent records confirmed email delivery for the provided finding IDs.
func (s *Store) MarkSent(ids []string, sentAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range ids {
		if tf, ok := s.data.Findings[id]; ok {
			tf.NotifiedCount++
			tf.LastNotified = sentAt
			tf.LastSeverity = tf.Severity
		}
	}
	s.data.LastUpdated = sentAt
	return s.saveLocked()
}

// Ack marks an active finding acknowledged (suppressing urgent reminders without closing it).
func (s *Store) Ack(id, note string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tf, ok := s.data.Findings[id]
	if !ok {
		return fmt.Errorf("finding %q not found", id)
	}
	if tf.Status == model.StatusResolved {
		return fmt.Errorf("finding %q is already resolved", id)
	}
	tf.Status = model.StatusAcked
	t := now
	tf.AcknowledgedAt = &t
	tf.AckNote = strings.TrimSpace(note)
	s.data.LastUpdated = now
	return s.saveLocked()
}

// UpsertSynthetic stores or updates a synthetic test finding separately from real OPNsense IDs.
func (s *Store) UpsertSynthetic(f model.Finding, now time.Time) (*model.TrackedFinding, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f.Synthetic = true
	if !strings.HasPrefix(f.ID, "synthetic:") {
		f.ID = "synthetic:" + f.ID
	}
	tf, exists := s.data.Findings[f.ID]
	if !exists || tf.Status == model.StatusResolved {
		tf = &model.TrackedFinding{
			Finding:      f,
			Status:       model.StatusOpen,
			LastSeverity: f.Severity,
		}
		tf.FirstSeen = now
		tf.LastSeen = now
		s.data.Findings[f.ID] = tf
	} else {
		tf.LastSeen = now
	}
	s.data.LastUpdated = now
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	cp := *tf
	return &cp, nil
}

// ResolveSynthetic closes a synthetic test finding when simulating clean recheck closure.
func (s *Store) ResolveSynthetic(id string, now time.Time) (*model.TrackedFinding, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !strings.HasPrefix(id, "synthetic:") {
		id = "synthetic:" + id
	}
	tf, ok := s.data.Findings[id]
	if !ok {
		return nil, fmt.Errorf("synthetic finding %q not found", id)
	}
	t := now
	tf.Status = model.StatusResolved
	tf.ResolvedAt = &t
	tf.LastSeen = now
	s.data.LastUpdated = now
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	cp := *tf
	return &cp, nil
}

// CleanupSynthetic removes all synthetic test entries from state.
func (s *Store) CleanupSynthetic(now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	removed := 0
	for id, tf := range s.data.Findings {
		if tf.Synthetic || strings.HasPrefix(id, "synthetic:") {
			delete(s.data.Findings, id)
			removed++
		}
	}
	s.data.LastUpdated = now
	return removed, s.saveLocked()
}

// DeleteSynthetic removes one synthetic entry by ID without disturbing other drills.
func (s *Store) DeleteSynthetic(id string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !strings.HasPrefix(id, "synthetic:") {
		id = "synthetic:" + id
	}
	if tf, ok := s.data.Findings[id]; ok && (tf.Synthetic || strings.HasPrefix(id, "synthetic:")) {
		delete(s.data.Findings, id)
		s.data.LastUpdated = now
		return s.saveLocked()
	}
	return nil
}
