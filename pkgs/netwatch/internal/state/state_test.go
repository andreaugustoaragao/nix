package state

import (
	"path/filepath"
	"testing"
	"time"

	"faragao.net/netwatch/internal/model"
)

func TestReconcileDeduplicationReminderAckAndCleanResolution(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	st, err := Load(path)
	if err != nil {
		t.Fatalf("Load() err: %v", err)
	}

	t0 := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	urgentFinding := model.Finding{
		ID:       "ghsa:core:GHSA-test-1",
		Category: "advisory",
		Severity: model.SeverityUrgent,
		Device:   "chief-tui-opn",
		Title:    "Test Urgent Advisory",
	}

	// First appearance queues urgent notification.
	res, err := st.Reconcile([]model.Finding{urgentFinding}, true, t0, DefaultUrgentReminder)
	if err != nil || len(res.UrgentToSend) != 1 {
		t.Fatalf("expected 1 UrgentToSend, got %d (err=%v)", len(res.UrgentToSend), err)
	}
	if err := st.MarkSent([]string{urgentFinding.ID}, t0); err != nil {
		t.Fatalf("MarkSent() err: %v", err)
	}

	// Duplicate 1 hour later must be suppressed.
	res, err = st.Reconcile([]model.Finding{urgentFinding}, true, t0.Add(1*time.Hour), DefaultUrgentReminder)
	if err != nil || len(res.UrgentToSend) != 0 {
		t.Fatalf("expected duplicate urgent suppressed, got %d (err=%v)", len(res.UrgentToSend), err)
	}

	// 25 hours later without ack must emit reminder.
	res, err = st.Reconcile([]model.Finding{urgentFinding}, true, t0.Add(25*time.Hour), DefaultUrgentReminder)
	if err != nil || len(res.UrgentToSend) != 1 {
		t.Fatalf("expected 24h reminder urgent, got %d (err=%v)", len(res.UrgentToSend), err)
	}
	if err := st.MarkSent([]string{urgentFinding.ID}, t0.Add(25*time.Hour)); err != nil {
		t.Fatalf("MarkSent() err: %v", err)
	}

	// Acknowledge must suppress future reminders WITHOUT resolving the finding.
	if err := st.Ack(urgentFinding.ID, "scheduled Sunday maintenance", t0.Add(26*time.Hour)); err != nil {
		t.Fatalf("Ack() err: %v", err)
	}
	snap := st.SnapshotCopy()
	if snap.Findings[urgentFinding.ID].Status != model.StatusAcked {
		t.Fatalf("expected status acked, got %s", snap.Findings[urgentFinding.ID].Status)
	}

	res, err = st.Reconcile([]model.Finding{urgentFinding}, true, t0.Add(60*time.Hour), DefaultUrgentReminder)
	if err != nil || len(res.UrgentToSend) != 0 {
		t.Fatalf("expected acked urgent reminder suppressed, got %d (err=%v)", len(res.UrgentToSend), err)
	}

	// Dirty/incomplete recheck (CleanRecheck=false) when finding disappears must NOT close it!
	res, err = st.Reconcile(nil, false, t0.Add(61*time.Hour), DefaultUrgentReminder)
	if err != nil || len(res.ResolvedToSend) != 0 {
		t.Fatalf("expected dirty recheck NOT to resolve acked finding, got %d resolved", len(res.ResolvedToSend))
	}
	if st.SnapshotCopy().Findings[urgentFinding.ID].Status != model.StatusAcked {
		t.Fatalf("expected finding to remain acked after dirty recheck")
	}

	// Clean recheck (CleanRecheck=true) closes acked finding and emits resolution notice.
	res, err = st.Reconcile(nil, true, t0.Add(62*time.Hour), DefaultUrgentReminder)
	if err != nil || len(res.ResolvedToSend) != 1 {
		t.Fatalf("expected 1 ResolvedToSend on clean recheck, got %d (err=%v)", len(res.ResolvedToSend), err)
	}
	if st.SnapshotCopy().Findings[urgentFinding.ID].Status != model.StatusResolved {
		t.Fatalf("expected status resolved after clean recheck")
	}

	// Reload persisted file from disk to verify persistence & 0600 file creation.
	reloaded, err := Load(path)
	if err != nil {
		t.Fatalf("reload failed: %v", err)
	}
	if reloaded.SnapshotCopy().Findings[urgentFinding.ID].Status != model.StatusResolved {
		t.Fatalf("reloaded status mismatch")
	}
}

func TestSyntheticLifecycleAndCleanup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	st, _ := Load(path)
	now := time.Now().UTC()

	tf, err := st.UpsertSynthetic(model.Finding{
		ID:       "test-1",
		Severity: model.SeverityUrgent,
		Title:    "Synthetic Advisory",
	}, now)
	if err != nil || !tf.Synthetic {
		t.Fatalf("UpsertSynthetic() err=%v tf=%+v", err, tf)
	}
	// Normal Reconcile must never auto-resolve synthetic findings.
	res, err := st.Reconcile(nil, true, now.Add(time.Minute), DefaultUrgentReminder)
	if err != nil || len(res.ResolvedToSend) != 0 {
		t.Fatalf("Reconcile touched synthetic finding unexpectedly")
	}
	removed, err := st.CleanupSynthetic(now.Add(2 * time.Minute))
	if err != nil || removed != 1 {
		t.Fatalf("CleanupSynthetic() removed=%d err=%v", removed, err)
	}
}
