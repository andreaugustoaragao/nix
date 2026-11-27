package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"faragao.net/netwatch/internal/config"
	"faragao.net/netwatch/internal/correlate"
	"faragao.net/netwatch/internal/feeds"
	"faragao.net/netwatch/internal/heartbeat"
	"faragao.net/netwatch/internal/model"
	"faragao.net/netwatch/internal/notify"
	"faragao.net/netwatch/internal/server"
	"faragao.net/netwatch/internal/state"
	"faragao.net/netwatch/internal/syslog"
)

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	sub := os.Args[1]
	args := os.Args[2:]

	var err error
	switch sub {
	case "serve":
		err = cmdServe(args)
	case "evaluate":
		err = cmdEvaluate(args)
	case "status":
		err = cmdStatus(args)
	case "ack":
		err = cmdAck(args)
	case "resolve":
		err = cmdResolve(args)
	case "accept-baseline":
		err = cmdAcceptBaseline(args)
	case "maintenance":
		err = cmdMaintenance(args)
	case "replay":
		err = cmdReplay(args)
	case "synthetic":
		err = cmdSynthetic(args)
	case "heartbeat":
		err = cmdHeartbeat(args)
	case "-h", "--help", "help":
		usage()
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n", sub)
		usage()
		os.Exit(2)
	}

	if err != nil {
		log.Fatalf("%s failed: %v", sub, err)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `netwatch — faragao.net firewall security, advisory, and heartbeat daemon

Usage:
  netwatch <command> [flags]

Commands:
  serve             Run HTTP ingest server, private TCP syslog receiver, and scheduler
  evaluate          Evaluate stored firewall snapshot + live feeds once
  status            Print current inventory, syslog telemetry, feed freshness, and findings
  ack               Acknowledge an active finding (suppresses reminders without closing)
  resolve           Manually resolve an open/acked security event finding
  accept-baseline   Promote current snapshot WAN exposure to the approved baseline
  maintenance       Set or clear a temporary maintenance window (--minutes N [--note ...])
  replay            Send labeled syslog/telemetry fixtures (--kind urgent|deny|duplicate|ids|syslog-silent)
  synthetic         Run labeled advisory drills (--kind urgent|unaffected|duplicate|stale|resolve|digest)
  heartbeat         Send a one-shot ping (or --fail) to Healthchecks.io`)
}

type engine struct {
	cfg       config.Config
	store     *state.Store
	fetcher   *feeds.Fetcher
	bundle    *feeds.FeedBundle
	bundleMu  sync.RWMutex
	evalMu    sync.Mutex
	startedAt time.Time
}

func newEngine(cfg config.Config, st *state.Store) *engine {
	return &engine{
		cfg:       cfg,
		store:     st,
		fetcher:   feeds.NewFetcher(),
		startedAt: time.Now().UTC(),
	}
}

func (e *engine) refreshFeeds(ctx context.Context) map[string]model.FeedStatus {
	prev := e.store.SnapshotCopy().FeedStatus
	now := time.Now().UTC()
	bundle, statuses := e.fetcher.FetchAll(ctx, prev, now)
	e.bundleMu.Lock()
	e.bundle = bundle
	e.bundleMu.Unlock()
	if err := e.store.RecordFeedStatuses(statuses, now); err != nil {
		log.Printf("warn: failed saving feed status: %v", err)
	}
	return statuses
}

func (e *engine) getBundle() *feeds.FeedBundle {
	e.bundleMu.RLock()
	defer e.bundleMu.RUnlock()
	return e.bundle
}

func (e *engine) evaluateAndNotify(ctx context.Context, snap *model.OPNsenseSnapshot, sendEmail bool) (correlate.EvaluateResult, state.ReconcileResult, int, error) {
	e.evalMu.Lock()
	defer e.evalMu.Unlock()

	now := time.Now().UTC()
	stCopy := e.store.SnapshotCopy()
	if snap != nil {
		if err := e.store.RecordSnapshot(snap, nil, now); err != nil {
			return correlate.EvaluateResult{}, state.ReconcileResult{}, 0, err
		}
		stCopy.LatestSnapshot = snap
	}

	bundle := e.getBundle()
	if bundle == nil {
		e.refreshFeeds(ctx)
		bundle = e.getBundle()
		stCopy = e.store.SnapshotCopy()
	}

	ev := correlate.Evaluate(stCopy.LatestSnapshot, bundle, stCopy.FeedStatus, now, e.cfg.StaleAfter)
	extra := correlate.EvaluateTelemetryAndExposure(stCopy, now, strings.TrimSpace(e.cfg.SyslogAddr) != "", e.cfg.SyslogStaleAfter, e.startedAt)
	ev.Findings = append(ev.Findings, extra...)
	rec, err := e.store.Reconcile(ev.Findings, ev.CleanRecheck, now, e.cfg.UrgentReminder)
	if err != nil {
		return ev, rec, 0, err
	}

	sent := 0
	if sendEmail {
		sent = e.dispatchUrgentAndResolutions(ctx, rec, now)
	}
	return ev, rec, sent, nil
}

func (e *engine) dispatchUrgentAndResolutions(ctx context.Context, rec state.ReconcileResult, now time.Time) int {
	sentCount := 0
	for _, tf := range rec.UrgentToSend {
		subj, body := notify.FormatUrgent(tf, now)
		if err := notify.Send(ctx, e.cfg.SMTP, subj, body); err != nil {
			log.Printf("error sending urgent email (%s): %v", tf.ID, err)
			continue
		}
		if err := e.store.MarkSent([]string{tf.ID}, now); err != nil {
			log.Printf("warn marking %s sent: %v", tf.ID, err)
		}
		log.Printf("sent urgent email for %s", tf.ID)
		sentCount++
	}
	if len(rec.ResolvedToSend) > 0 {
		subj, body := notify.FormatResolution(rec.ResolvedToSend, now)
		if err := notify.Send(ctx, e.cfg.SMTP, subj, body); err != nil {
			log.Printf("error sending resolution email: %v", err)
		} else {
			log.Printf("sent resolution email for %d finding(s)", len(rec.ResolvedToSend))
		}
	}
	return sentCount
}

func (e *engine) maybeSendScheduledEmails(ctx context.Context, rec state.ReconcileResult, forceDaily, forceDigest, dryRun bool) error {
	now := time.Now()
	stCopy := e.store.SnapshotCopy()

	dailyDue := forceDaily || (now.Hour() >= e.cfg.DailyHour && !sameLocalDate(stCopy.LastDailySent, now))
	if dailyDue && len(rec.DailyCandidates) > 0 {
		subj, body := notify.FormatDailyAction(rec.DailyCandidates, stCopy, now)
		if dryRun {
			fmt.Printf("=== DRY RUN DAILY ===\nSubject: %s\n\n%s\n", subj, body)
		} else {
			if err := notify.Send(ctx, e.cfg.SMTP, subj, body); err != nil {
				return fmt.Errorf("daily email: %w", err)
			}
			ids := make([]string, 0, len(rec.DailyCandidates))
			for _, f := range rec.DailyCandidates {
				ids = append(ids, f.ID)
			}
			_ = e.store.MarkSent(ids, now.UTC())
			_ = e.store.MarkDailySent(now.UTC())
			log.Printf("sent daily security action email (%d items)", len(rec.DailyCandidates))
		}
	}

	digestDue := forceDigest || (now.Weekday() == e.cfg.DigestWeekday && now.Hour() >= e.cfg.DigestHour && now.Sub(stCopy.LastDigestSent) > 6*24*time.Hour)
	if digestDue {
		subj, body := notify.FormatWeeklyDigest(stCopy, rec.DigestCandidates, false, now)
		if dryRun {
			fmt.Printf("=== DRY RUN DIGEST ===\nSubject: %s\n\n%s\n", subj, body)
		} else {
			if err := notify.Send(ctx, e.cfg.SMTP, subj, body); err != nil {
				return fmt.Errorf("weekly digest email: %w", err)
			}
			_ = e.store.MarkDigestSent(now.UTC())
			log.Printf("sent weekly digest email")
		}
	}
	return nil
}

func cmdServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	if strings.TrimSpace(cfg.IngestToken) == "" {
		return errors.New("NETWATCH_INGEST_TOKEN is required in serve mode")
	}
	if err := cfg.SMTP.Validate(); err != nil {
		return fmt.Errorf("invalid SMTP config: %w", err)
	}
	st, err := state.Load(cfg.StateFile)
	if err != nil {
		return err
	}

	eng := newEngine(cfg, st)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Send initial Healthchecks.io heartbeat if configured.
	sendHB := func() {
		if strings.TrimSpace(cfg.HeartbeatURL) == "" {
			return
		}
		stCopy := st.SnapshotCopy()
		status := fmt.Sprintf("netwatch ok; snapshot=%v", stCopy.LatestSnapshot != nil)
		err := heartbeat.Ping(ctx, nil, cfg.HeartbeatURL, false, status)
		if err != nil {
			log.Printf("warn: heartbeat ping failed: %v", err)
			_ = st.RecordHeartbeat(false, err.Error(), time.Now().UTC())
		} else {
			_ = st.RecordHeartbeat(true, "", time.Now().UTC())
		}
	}

	det := syslog.NewDetector(syslog.Policy{
		AllowedAdminUsers:      cfg.AdminUsers,
		AllowedAdminCIDRs:      cfg.AdminSourceCIDRs,
		WANInterface:           cfg.WANInterface,
		AllowedWANInboundPorts: cfg.AllowedWANInboundPorts,
	})

	if strings.TrimSpace(cfg.SyslogAddr) != "" {
		rec, err := syslog.Listen(cfg.SyslogAddr, cfg.AllowedSyslogIPs, func(msg syslog.Message) {
			now := msg.ReceivedAt
			if now.IsZero() {
				now = time.Now().UTC()
			}
			finding, delta := det.Process(msg, st.IsMaintenanceActive(now))
			if !msg.Synthetic {
				if err := st.RecordSyslogStats(now, delta.WANBlockedIn, delta.InternalOutboundBlocked, delta.ExpectedAdminLogins, delta.IDSAlertsUrgent, delta.IDSAlertsDigest, delta.BlockedPort, 30*time.Second); err != nil {
					log.Printf("warn saving syslog stats: %v", err)
				}
			}
			if finding == nil {
				return
			}
			tf, shouldSend, err := st.RecordEventFinding(*finding, now, cfg.UrgentReminder)
			if err != nil {
				log.Printf("error recording syslog finding (%s): %v", finding.ID, err)
				return
			}
			if !shouldSend {
				return
			}
			subj, body := notify.FormatUrgent(tf, now)
			sendCtx, sendCancel := context.WithTimeout(ctx, 20*time.Second)
			defer sendCancel()
			if err := notify.Send(sendCtx, cfg.SMTP, subj, body); err != nil {
				log.Printf("error sending syslog urgent email (%s): %v", tf.ID, err)
				return
			}
			_ = st.MarkSent([]string{tf.ID}, now)
			log.Printf("sent urgent syslog email for %s (synthetic=%v)", tf.ID, tf.Synthetic)
		})
		if err != nil {
			return fmt.Errorf("listen syslog %s: %w", cfg.SyslogAddr, err)
		}
		go func() {
			log.Printf("netwatch syslog listening on %s", rec.Addr())
			if err := rec.Serve(ctx); err != nil {
				log.Printf("syslog receiver exited: %v", err)
			}
		}()
	}

	adminHandlers := &server.AdminHandlers{
		Status: func(_ context.Context) (any, error) {
			return st.SnapshotCopy(), nil
		},
		Ack: func(_ context.Context, id, note string) error {
			return st.Ack(id, note, time.Now().UTC())
		},
		Resolve: func(_ context.Context, id string) (any, error) {
			return st.ResolveFinding(id, time.Now().UTC())
		},
		AcceptBaseline: func(_ context.Context) error {
			return st.AcceptBaseline(time.Now().UTC())
		},
		Maintenance: func(_ context.Context, minutes int, note string) (any, error) {
			now := time.Now().UTC()
			if minutes <= 0 {
				if err := st.SetMaintenance(nil, "", now); err != nil {
					return nil, err
				}
				return map[string]any{"ok": true, "maintenance_active": false}, nil
			}
			until := now.Add(time.Duration(minutes) * time.Minute)
			if err := st.SetMaintenance(&until, note, now); err != nil {
				return nil, err
			}
			return map[string]any{"ok": true, "maintenance_active": true, "maintenance_until": until.Format(time.RFC3339), "note": note}, nil
		},
		CleanupSynthetic: func(_ context.Context) (int, error) {
			return st.CleanupSynthetic(time.Now().UTC())
		},
	}

	mux := server.NewMuxWithAdmin(cfg.IngestToken, func(c context.Context, snap *model.OPNsenseSnapshot) (int, int, error) {
		ev, _, sent, err := eng.evaluateAndNotify(c, snap, true)
		if err != nil {
			return 0, 0, err
		}
		return len(ev.Findings), sent, nil
	}, func() map[string]any {
		cp := st.SnapshotCopy()
		out := map[string]any{
			"service":            "netwatch",
			"open_findings":      countOpen(cp.Findings),
			"syslog_events":      cp.Syslog.TotalReceived,
			"maintenance_active": st.IsMaintenanceActive(time.Now().UTC()),
		}
		if cp.LatestSnapshot != nil {
			out["last_snapshot"] = cp.LatestSnapshot.CollectedAt.UTC().Format(time.RFC3339)
			out["opnsense_version"] = cp.LatestSnapshot.ProductVersion
		}
		if !cp.Syslog.LastReceived.IsZero() {
			out["last_syslog"] = cp.Syslog.LastReceived.UTC().Format(time.RFC3339)
		}
		return out
	}, adminHandlers)

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("netwatch listening on %s (state=%s)", cfg.ListenAddr, cfg.StateFile)
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	go func() {
		// Warm advisory feeds on startup after listener is ready.
		eng.refreshFeeds(ctx)
		if st.SnapshotCopy().LatestSnapshot != nil {
			_, _, _, _ = eng.evaluateAndNotify(ctx, nil, true)
		}
		sendHB()

		hbTicker := time.NewTicker(cfg.HeartbeatInterval)
		feedTicker := time.NewTicker(cfg.FeedInterval)
		schedTicker := time.NewTicker(1 * time.Minute)
		defer hbTicker.Stop()
		defer feedTicker.Stop()
		defer schedTicker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-hbTicker.C:
				sendHB()
			case <-feedTicker.C:
				eng.refreshFeeds(ctx)
				_, rec, _, err := eng.evaluateAndNotify(ctx, nil, true)
				if err != nil {
					log.Printf("feed eval error: %v", err)
				} else {
					_ = eng.maybeSendScheduledEmails(ctx, rec, false, false, false)
				}
			case <-schedTicker.C:
				stCopy := st.SnapshotCopy()
				// Avoid false no-snapshot alarm within the first 15m after initial boot before OPNsense first push.
				if stCopy.LatestSnapshot == nil && time.Since(eng.startedAt) < 15*time.Minute {
					continue
				}
				_, rec, _, err := eng.evaluateAndNotify(ctx, nil, true)
				if err != nil {
					log.Printf("sched eval error: %v", err)
					continue
				}
				if err := eng.maybeSendScheduledEmails(ctx, rec, false, false, false); err != nil {
					log.Printf("scheduled email error: %v", err)
				}
			}
		}
	}()

	select {
	case <-ctx.Done():
		if err := st.Save(); err != nil {
			log.Printf("warn saving state on shutdown: %v", err)
		}
		shCtx, shCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shCancel()
		return srv.Shutdown(shCtx)
	case err := <-errCh:
		return err
	}
}

func cmdEvaluate(args []string) error {
	fs := flag.NewFlagSet("evaluate", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	forceDaily := fs.Bool("force-daily", false, "Send/print daily security notice now")
	forceDigest := fs.Bool("force-digest", false, "Send/print weekly digest now")
	dryRun := fs.Bool("dry-run", false, "Print actions without sending email")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	st, err := state.Load(cfg.StateFile)
	if err != nil {
		return err
	}
	eng := newEngine(cfg, st)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	eng.refreshFeeds(ctx)
	ev, rec, _, err := eng.evaluateAndNotify(ctx, nil, !*dryRun)
	if err != nil {
		return err
	}
	if err := eng.maybeSendScheduledEmails(ctx, rec, *forceDaily, *forceDigest, *dryRun); err != nil {
		return err
	}
	fmt.Printf("evaluated %d active finding(s), clean_recheck=%v, urgent_queued=%d, daily=%d, digest=%d, resolved=%d\n",
		len(ev.Findings), ev.CleanRecheck, len(rec.UrgentToSend), len(rec.DailyCandidates), len(rec.DigestCandidates), len(rec.ResolvedToSend))
	return nil
}

func cmdStatus(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	var cp model.State
	if used, err := tryAdminRequest(cfg, http.MethodGet, "/admin/status", nil, &cp); err != nil {
		return err
	} else if !used {
		st, err := state.Load(cfg.StateFile)
		if err != nil {
			return err
		}
		cp = st.SnapshotCopy()
	}

	if cp.LatestSnapshot != nil {
		s := cp.LatestSnapshot
		fmt.Printf("Snapshot: %s | OPNsense %s (%s) | FreeBSD %s | collected=%s | audit_ok=%v | pkgs=%d\n",
			s.Host, s.ProductVersion, s.Edition, s.FreeBSDKernel, s.CollectedAt.UTC().Format(time.RFC3339), s.AuditOK, s.PackageCount)
	} else {
		fmt.Println("Snapshot: none")
	}
	if !cp.LastHeartbeatOK.IsZero() {
		fmt.Printf("Heartbeat: last_ok=%s err=%q\n", cp.LastHeartbeatOK.UTC().Format(time.RFC3339), cp.LastHeartbeatErr)
	}
	if !cp.Syslog.LastReceived.IsZero() {
		fmt.Printf("Syslog: last=%s total=%d wan_blocks=%d out_blocks=%d admin_ok=%d ids_urgent=%d ids_digest=%d\n",
			cp.Syslog.LastReceived.UTC().Format(time.RFC3339), cp.Syslog.TotalReceived, cp.Syslog.WANBlockedIn,
			cp.Syslog.InternalOutboundBlocked, cp.Syslog.ExpectedAdminLogins, cp.Syslog.IDSAlertsUrgent, cp.Syslog.IDSAlertsDigest)
	} else {
		fmt.Println("Syslog: none")
	}
	if cp.MaintenanceUntil != nil && time.Now().UTC().Before(*cp.MaintenanceUntil) {
		fmt.Printf("Maintenance: ACTIVE until %s (%s)\n", cp.MaintenanceUntil.UTC().Format(time.RFC3339), cp.MaintenanceNote)
	}
	var ids []string
	for id := range cp.Findings {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	fmt.Printf("Findings (%d tracked):\n", len(ids))
	for _, id := range ids {
		tf := cp.Findings[id]
		fmt.Printf("  - %-40s | %-6s | %-8s | sent=%d | %s\n", id, tf.Severity, tf.Status, tf.NotifiedCount, tf.Title)
	}
	return nil
}

func cmdAck(args []string) error {
	fs := flag.NewFlagSet("ack", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	id := fs.String("id", "", "Finding ID to acknowledge")
	note := fs.String("note", "", "Optional acknowledgement note")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*id) == "" {
		return errors.New("--id is required")
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	used, err := tryAdminRequest(cfg, http.MethodPost, "/admin/ack", map[string]string{
		"id":   strings.TrimSpace(*id),
		"note": *note,
	}, nil)
	if err != nil {
		return err
	}
	if !used {
		st, err := state.Load(cfg.StateFile)
		if err != nil {
			return err
		}
		if err := st.Ack(strings.TrimSpace(*id), *note, time.Now().UTC()); err != nil {
			return err
		}
	}
	fmt.Printf("acknowledged %s (remains open until clean recheck/resolve closes it)\n", *id)
	return nil
}

func cmdResolve(args []string) error {
	fs := flag.NewFlagSet("resolve", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	id := fs.String("id", "", "Finding ID to resolve")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*id) == "" {
		return errors.New("--id is required")
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	used, err := tryAdminRequest(cfg, http.MethodPost, "/admin/resolve", map[string]string{
		"id": strings.TrimSpace(*id),
	}, nil)
	if err != nil {
		return err
	}
	if !used {
		st, err := state.Load(cfg.StateFile)
		if err != nil {
			return err
		}
		if _, err := st.ResolveFinding(strings.TrimSpace(*id), time.Now().UTC()); err != nil {
			return err
		}
	}
	fmt.Printf("resolved %s\n", *id)
	return nil
}

func cmdAcceptBaseline(args []string) error {
	fs := flag.NewFlagSet("accept-baseline", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	used, err := tryAdminRequest(cfg, http.MethodPost, "/admin/accept-baseline", nil, nil)
	if err != nil {
		return err
	}
	if !used {
		st, err := state.Load(cfg.StateFile)
		if err != nil {
			return err
		}
		if err := st.AcceptBaseline(time.Now().UTC()); err != nil {
			return err
		}
	}
	fmt.Println("promoted current WAN exposure to approved baseline")
	return nil
}

func cmdMaintenance(args []string) error {
	fs := flag.NewFlagSet("maintenance", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	minutes := fs.Int("minutes", 60, "Duration in minutes (<=0 clears window)")
	note := fs.String("note", "planned maintenance", "Maintenance reason note")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	used, err := tryAdminRequest(cfg, http.MethodPost, "/admin/maintenance", map[string]any{
		"minutes": *minutes,
		"note":    *note,
	}, nil)
	if err != nil {
		return err
	}
	if !used {
		st, err := state.Load(cfg.StateFile)
		if err != nil {
			return err
		}
		now := time.Now().UTC()
		if *minutes <= 0 {
			if err := st.SetMaintenance(nil, "", now); err != nil {
				return err
			}
		} else {
			until := now.Add(time.Duration(*minutes) * time.Minute)
			if err := st.SetMaintenance(&until, *note, now); err != nil {
				return err
			}
		}
	}
	if *minutes <= 0 {
		fmt.Println("cleared maintenance window")
	} else {
		fmt.Printf("enabled maintenance window for %d minutes (%s)\n", *minutes, *note)
	}
	return nil
}

func cmdReplay(args []string) error {
	fs := flag.NewFlagSet("replay", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	addr := fs.String("addr", "", "Syslog TCP target (default 127.0.0.1:<syslog port>)")
	kind := fs.String("kind", "urgent", "Fixture kind: urgent|deny|duplicate|ids|syslog-silent")
	send := fs.Bool("send", false, "Send labeled [SYNTHETIC TEST] email directly when kind=syslog-silent")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	target := strings.TrimSpace(*addr)
	if target == "" {
		port := "5514"
		if _, p, err := net.SplitHostPort(cfg.SyslogAddr); err == nil && p != "" {
			port = p
		}
		target = "127.0.0.1:" + port
	}

	now := time.Now().UTC()
	ts := now.Format(time.RFC3339)
	switch *kind {
	case "urgent", "duplicate":
		line := fmt.Sprintf(`<38>1 %s chief-tui-opn.faragao.net sshd 99999 - [SYNTHETIC TEST] Accepted publickey for root from 192.168.30.99 port 51234 ssh2 [SYNTHETIC TEST] token=secret123`, ts)
		if err := syslog.SendFixture(target, line); err != nil {
			return err
		}
		fmt.Printf("replayed syslog %s fixture to %s\n", *kind, target)
	case "deny":
		line := fmt.Sprintf(`<134>1 %s chief-tui-opn.faragao.net filterlog 99999 - [SYNTHETIC TEST] 5,,,syn0001,igc1,match,block,in,4,0x0,,248,1,0,none,6,tcp,44,198.51.100.77,174.16.196.251,51919,56332,0,S,1,,65535,,mss`, ts)
		if err := syslog.SendFixture(target, line); err != nil {
			return err
		}
		fmt.Printf("replayed routine deny syslog fixture to %s (no urgent email expected)\n", target)
	case "ids":
		line := fmt.Sprintf(`<134>1 %s chief-tui-opn.faragao.net suricata 99999 - [SYNTHETIC TEST] [1:2010935:4] [SYNTHETIC TEST] ET MALWARE Suspect C2 Beacon [Classification: A Network Trojan was detected] [Priority: 1] {TCP} 192.168.30.50:49152 -> 203.0.113.10:8080`, ts)
		if err := syslog.SendFixture(target, line); err != nil {
			return err
		}
		fmt.Printf("replayed Suricata P1 IDS lead fixture to %s\n", target)
	case "syslog-silent":
		tf := model.TrackedFinding{
			Finding: model.Finding{
				ID:                "synthetic:syslog-silent",
				Category:          "stale_monitor",
				Severity:          model.SeverityUrgent,
				Device:            "chief-tui-opn.faragao.net",
				Title:             "SYNTHETIC OPNsense Firewall Syslog Telemetry Silence Drill",
				Summary:           fmt.Sprintf("Simulated >%s gap on private TCP :5514 syslog telemetry (distinct from daily opn-audit-export).", cfg.SyslogStaleAfter),
				RunningVersion:    "syslog-tcp:5514",
				FixedVersion:      "Verify OPNsense System -> Settings -> Logging -> Remote targets",
				Exposure:          "Live syslog blind spot",
				RebootExpected:    "no",
				RecommendedTiming: "SYNTHETIC DRILL — verify distinct fault format & delivery",
				Sources:           []string{"syslog-tcp"},
				Synthetic:         true,
			},
			Status: model.StatusOpen,
		}
		subj, body := notify.FormatUrgent(tf, now)
		if *send {
			if err := notify.Send(context.Background(), cfg.SMTP, subj, body); err != nil {
				return err
			}
			fmt.Println("SYNTHETIC SYSLOG SILENCE EMAIL SENT")
		} else {
			fmt.Printf("Subject: %s\n\n%s\n", subj, body)
		}
	default:
		return fmt.Errorf("unknown replay kind %q", *kind)
	}
	return nil
}

func loopbackAdminAddr(listenAddr string) string {
	_, port, err := net.SplitHostPort(strings.TrimSpace(listenAddr))
	if err != nil || port == "" {
		port = "9400"
	}
	return "127.0.0.1:" + port
}

func tryAdminRequest(cfg config.Config, method, path string, reqBody any, out any) (bool, error) {
	if strings.TrimSpace(cfg.IngestToken) == "" {
		return false, nil
	}
	var bodyReader io.Reader
	if reqBody != nil {
		raw, err := json.Marshal(reqBody)
		if err != nil {
			return false, err
		}
		bodyReader = bytes.NewReader(raw)
	}
	url := "http://" + loopbackAdminAddr(cfg.ListenAddr) + path
	req, err := http.NewRequestWithContext(context.Background(), method, url, bodyReader)
	if err != nil {
		return false, nil
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(cfg.IngestToken))
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return false, nil // serve daemon not reachable locally; fall back to file store
	}
	defer resp.Body.Close()
	rawResp, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return true, fmt.Errorf("admin %s returned HTTP %d: %s", path, resp.StatusCode, strings.TrimSpace(string(rawResp)))
	}
	if out != nil {
		if err := json.Unmarshal(rawResp, out); err != nil {
			return true, fmt.Errorf("decode %s response: %w", path, err)
		}
	}
	return true, nil
}

func cmdSynthetic(args []string) error {
	fs := flag.NewFlagSet("synthetic", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	kind := fs.String("kind", "urgent", "Scenario: urgent|unaffected|duplicate|stale|resolve|digest")
	send := fs.Bool("send", false, "Send labeled [SYNTHETIC TEST] email via configured SMTP")
	cleanup := fs.Bool("cleanup", false, "Remove all synthetic test entries from state")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	now := time.Now().UTC()

	if *cleanup {
		var res struct {
			Removed int `json:"removed"`
		}
		if used, err := tryAdminRequest(cfg, http.MethodPost, "/admin/cleanup-synthetic", nil, &res); err != nil {
			return err
		} else if used {
			fmt.Printf("cleaned up %d synthetic finding(s)\n", res.Removed)
			return nil
		}
		st, err := state.Load(cfg.StateFile)
		if err != nil {
			return err
		}
		n, err := st.CleanupSynthetic(now)
		if err != nil {
			return err
		}
		fmt.Printf("cleaned up %d synthetic finding(s)\n", n)
		return nil
	}

	st, err := state.Load(cfg.StateFile)
	if err != nil {
		return err
	}

	var subj, body string
	switch *kind {
	case "urgent":
		tf, err := st.UpsertSynthetic(model.Finding{
			ID:                "synthetic:advisory-kev",
			Category:          "advisory",
			Severity:          model.SeverityUrgent,
			Device:            "chief-tui-opn.faragao.net",
			Title:             "SYNTHETIC OPNsense KEV Advisory Drill (CVE-2099-0001)",
			Summary:           "Simulated affected WAN-exposed advisory matching installed firewall inventory.",
			RunningVersion:    "opnsense 26.7.10 (community)",
			FixedVersion:      "26.7.11 (synthetic drill)",
			Mitigation:        "Verify email delivery with Matrix stopped, then run synthetic --kind resolve.",
			Exposure:          "WAN=igc1 (1 pass rule, 1 NAT rdr)",
			RebootExpected:    "no",
			RecommendedTiming: "SYNTHETIC DRILL — verify receipt",
			CVEs:              []string{"CVE-2099-0001"},
			KEV:               true,
			Sources:           []string{"https://docs.opnsense.org/security.html"},
		}, now)
		if err != nil {
			return err
		}
		subj, body = notify.FormatUrgent(*tf, now)
		if *send {
			if err := notify.Send(context.Background(), cfg.SMTP, subj, body); err != nil {
				return err
			}
			_ = st.MarkSent([]string{tf.ID}, now)
		}
	case "unaffected":
		snap := &model.OPNsenseSnapshot{
			Host:           "chief-tui-opn.faragao.net",
			CollectedAt:    now,
			Edition:        "community",
			ProductVersion: "26.7.10",
			ProductSeries:  "26.7",
			AuditOK:        true,
			Plugins:        []model.PackageInfo{{Name: "os-ddclient", Version: "1.34"}},
		}
		bundle := &feeds.FeedBundle{
			KEVByCVE: map[string]feeds.KEVEntry{},
			CoreGHSAs: []feeds.GHSAAdvisory{
				{
					GHSAID:   "GHSA-89wp-xvvm-9pp4",
					Severity: "high",
					Summary:  "Affected only <= 26.7.9 and 26.10.0p1",
					Vulnerabilities: []feeds.GHSAVulnerability{{
						VulnerableVersionRange: "<= 26.7.9, 26.10.0p1",
						PatchedVersions:        "26.7.10",
					}},
				},
				{
					GHSAID:   "GHSA-75fw-j788-j4hj",
					Severity: "medium",
					Summary:  "Affected >= 26.7.1, patched in 26.7.2",
					Vulnerabilities: []feeds.GHSAVulnerability{{
						VulnerableVersionRange: ">= 26.7.1",
						PatchedVersions:        "26.7.2",
					}},
				},
			},
			PluginGHSAs: []feeds.GHSAAdvisory{{
				GHSAID:   "GHSA-uninstalled-plugin",
				Severity: "critical",
				Vulnerabilities: []feeds.GHSAVulnerability{{
					Package:                feeds.GHSAPackage{Name: "os-caddy"},
					VulnerableVersionRange: "<= 9.9.9",
				}},
			}},
		}
		statuses := map[string]model.FeedStatus{
			feeds.FeedKEV:           {Name: feeds.FeedKEV, LastSuccess: now},
			feeds.FeedCoreGHSA:      {Name: feeds.FeedCoreGHSA, LastSuccess: now},
			feeds.FeedPluginsGHSA:   {Name: feeds.FeedPluginsGHSA, LastSuccess: now},
			feeds.FeedAnnouncements: {Name: feeds.FeedAnnouncements, LastSuccess: now},
		}
		res := correlate.Evaluate(snap, bundle, statuses, now, correlate.DefaultStaleAfter)
		if len(res.Findings) != 0 {
			return fmt.Errorf("expected 0 findings for unaffected drill, got %d", len(res.Findings))
		}
		fmt.Println("SYNTHETIC unaffected drill PASSED: 0 false positives (filtered fixed 26.7.10, business 26.10.0p1, and uninstalled os-caddy)")
		return nil
	case "duplicate":
		tf, err := st.UpsertSynthetic(model.Finding{
			ID:       "synthetic:dup-drill",
			Severity: model.SeverityUrgent,
			Device:   "chief-tui-opn.faragao.net",
			Title:    "Synthetic Deduplication Drill",
		}, now)
		if err != nil {
			return err
		}
		_ = st.MarkSent([]string{tf.ID}, now)
		cp := st.SnapshotCopy().Findings[tf.ID]
		if cp.NotifiedCount < 1 {
			return errors.New("duplicate drill setup failed")
		}
		_ = st.DeleteSynthetic(tf.ID, now)
		fmt.Printf("SYNTHETIC duplicate suppression verified (notified_count=%d suppressed within %s reminder window)\n",
			cp.NotifiedCount, cfg.UrgentReminder)
		return nil
	case "stale":
		f := model.TrackedFinding{
			Finding: model.Finding{
				ID:                "synthetic:stale-audit",
				Category:          "stale_monitor",
				Severity:          model.SeverityUrgent,
				Device:            "chief-tui-opn.faragao.net",
				Title:             "SYNTHETIC Stale Audit Drill (55h since last snapshot)",
				Summary:           "Simulated missed daily audit threshold exceeded.",
				RunningVersion:    "26.7.10",
				FixedVersion:      "Verify firewall cron & exporter",
				Exposure:          "Monitoring blind spot",
				RebootExpected:    "no",
				RecommendedTiming: "SYNTHETIC DRILL — verify receipt",
				Synthetic:         true,
			},
			Status: model.StatusOpen,
		}
		subj, body = notify.FormatUrgent(f, now)
		if *send {
			if err := notify.Send(context.Background(), cfg.SMTP, subj, body); err != nil {
				return err
			}
		}
	case "resolve":
		tf, err := st.ResolveSynthetic("synthetic:advisory-kev", now)
		if err != nil {
			return err
		}
		subj, body = notify.FormatResolution([]model.TrackedFinding{*tf}, now)
		if *send {
			if err := notify.Send(context.Background(), cfg.SMTP, subj, body); err != nil {
				return err
			}
		}
	case "digest":
		subj, body = notify.FormatWeeklyDigest(st.SnapshotCopy(), nil, true, now)
		if *send {
			if err := notify.Send(context.Background(), cfg.SMTP, subj, body); err != nil {
				return err
			}
		}
	default:
		return fmt.Errorf("unknown synthetic kind %q", *kind)
	}

	fmt.Printf("Subject: %s\n\n%s\n", subj, body)
	if *send {
		fmt.Println("SYNTHETIC EMAIL SENT")
	}
	return nil
}

func cmdHeartbeat(args []string) error {
	fs := flag.NewFlagSet("heartbeat", flag.ExitOnError)
	envFile := fs.String("env-file", "", "Optional environment file path")
	fail := fs.Bool("fail", false, "Send /fail signal to Healthchecks.io")
	note := fs.String("note", "manual heartbeat check", "Status note")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	if err := heartbeat.Ping(context.Background(), nil, cfg.HeartbeatURL, *fail, *note); err != nil {
		return err
	}
	fmt.Printf("heartbeat ping sent (fail=%v)\n", *fail)
	return nil
}

func sameLocalDate(a, b time.Time) bool {
	if a.IsZero() {
		return false
	}
	ay, am, ad := a.Local().Date()
	by, bm, bd := b.Local().Date()
	return ay == by && am == bm && ad == bd
}

func countOpen(m map[string]*model.TrackedFinding) int {
	n := 0
	for _, tf := range m {
		if !tf.Synthetic && tf.Status != model.StatusResolved {
			n++
		}
	}
	return n
}
