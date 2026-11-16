// @ts-check
import { View, div, svg, PathBuilder, Background } from "gpui-kit";
import { h_flex, v_flex, Button } from "gpui-base";
import { spaces, terminals, machines, props, shared, setShared, run, layout, theme, exec, readTextFile, nextCommand, home } from "herdr";
import { parseSnapshot, parseSource, observedTerminals, age, time, deadline, historyGeometry, activityGeometry, freshness, checkpointState, compactText, decisions, inspection } from "./model.js";

/** @param {unknown} value @returns {value is import('gpui-kit').Color} */
function isColor(value) { return typeof value === "string" && /^#[0-9a-f]{3,8}$/i.test(value); }
function palette() {
  return Object.fromEntries(Object.entries(theme()).map(([key, value]) => [key, isColor(value) ? value : "#808080"]));
}
/** @param {import('gpui-kit').Color} color */
function tint(color) {
  const hex = color.slice(1);
  const opaque = hex.length >= 6 ? hex.slice(0, 6) : hex.slice(0, 3).split("").map((part) => part + part).join("");
  const value = `#${opaque}22`;
  return isColor(value) ? value : color;
}

/** @typedef {import('./model.js').Snapshot} Snapshot */
/** @typedef {import('./model.js').Task} Task */
/** @param {unknown} node @param {string} id @returns {Record<string, unknown> | null} */
function find(node, id) {
  if (!node || typeof node !== "object") return null;
  if ("id" in node && node.id === id) return Object.fromEntries(Object.entries(node));
  if ("children" in node && Array.isArray(node.children)) {
    for (const child of node.children) { const result = find(child, id); if (result) return result; }
  }
  return null;
}

/** @param {string} terminal @param {string | null | undefined} machine */
function controllerTerminal(terminal, machine) {
  return machine && !terminal.includes("/") ? `${machine}/${terminal}` : terminal;
}

export default class Work extends View {
  /** @type {string | null} */ space = null;
  /** @type {string | null} */ sourcePath = null;
  busy = false;
  notificationBusy = false;
  locatedAt = 0;
  width = 400;
  requestedSpace = "";
  now = Date.now();
  /** @type {string | null} */ selectedTask = null;
  /** @type {string | null} */ selection = null;
  /** @type {ReturnType<import('gpui-kit').Context['focus_handle']> | null} */ handle = null;

  /** @param {unknown} _props @param {import('gpui-kit').AsyncContext} cx */
  init(_props, cx) {
    this.handle = cx.focus_handle();
    cx.timer.every(30000, (cx) => this.tick(cx));
    cx.spawn(async (cx) => {
      for (;;) {
        const command = await nextCommand();
        if (command === "focus") this.handle?.focus();
        if (command === "refresh") this.refresh(cx, true);
      }
    });
    this.refresh(cx);
  }

  /** @param {import('gpui-kit').Context} cx */
  tick(cx) {
    const now = Date.now();
    const visible = props()?.compact === true || typeof props()?.source === "string" ||
      (find(layout(), "panel")?.hidden === false && find(layout(), "panel-body")?.active === "work-progress");
    if (visible && Math.floor(now / 60000) !== Math.floor(this.now / 60000)) {
      this.now = now;
      cx.notify();
    }
    this.refresh(cx);
  }

  /** @param {string} key */
  source(key) {
    try { return parseSource(shared(key)); } catch { return { snapshot: null, error: null, path: null, readAt: 0, notice: null }; }
  }

  /** @param {import('gpui-kit').Context} cx @param {boolean} force */
  refresh(cx, force = false) {
    const space = spaces().find((s) => s.active);
    const fixturePath = typeof props()?.source === "string" ? props().source : null;
    if (!space) return;
    const id = fixturePath ? `fixture:${fixturePath}` : space.id;
    // Desktop qualifies remote IDs; discovery and ownership stay native to each core.
    const sourceSpaceId = space.machine && space.id.startsWith(`${space.machine}/`)
      ? space.id.slice(space.machine.length + 1) : space.id;
    const key = `work.source.${id}`;
    const cached = this.source(key);
    const compact = props()?.compact === true;
    const canNotify = compact && !fixturePath && !space.machine;
    // Notifications consume valid cached decisions even when another view owns the latest read.
    if (canNotify) this.processNotifications(cx, key);
    if (this.busy) return;
    const open = find(layout(), "panel")?.hidden === false && find(layout(), "panel-body")?.active === "work-progress";
    // The always-present compact copy owns polling; an open standalone panel can recover without it.
    if (!force && !compact && !fixturePath && !open) return;
    if (!force && Date.now() - cached.readAt < 25000) return;
    this.busy = true;
    cx.spawn(async (cx) => {
      let snapshot = cached.snapshot;
      let path = fixturePath || (this.space === id ? this.sourcePath : null);
      let error = null;
      let notice = cached.notice;
      try {
        if (!path || Date.now() - this.locatedAt > 60000) {
          if (!fixturePath) {
            const helper = space.machine ? "chief-of-staff-work" : home() + "/.local/bin/chief-of-staff-work";
            const result = await exec(helper, ["locate", "--space", sourceSpaceId], { on: space.machine, timeout: 5000 });
            if (result.code !== 0) throw Error("No registered Work source; run chief-of-staff-init in the coordinator");
            /** @type {unknown} */ const found = JSON.parse(result.stdout);
            if (!found || typeof found !== "object" || !("snapshot" in found) || typeof found.snapshot !== "string") throw Error("Invalid discovery index");
            path = found.snapshot;
          }
          this.locatedAt = Date.now();
        }
        const raw = await readTextFile(path, { on: fixturePath ? null : space.machine });
        if (raw === null) throw Error("Work snapshot missing; coordinator must repair publication");
        /** @type {unknown} */ const value = JSON.parse(raw);
        const parsed = parseSnapshot(value);
        if (fixturePath && !parsed.registration.fixture) throw Error("Fixture source must be explicitly labeled");
        if (!fixturePath && parsed.registration.space !== sourceSpaceId) throw Error("Source belongs to a different space");
        if (snapshot && snapshot.registration.portfolio === parsed.registration.portfolio && parsed.seq < snapshot.seq) throw Error("Snapshot sequence moved backwards; showing retained history");
        snapshot = parsed;
      } catch (failure) {
        error = failure instanceof Error ? failure.message : "Work source unavailable";
      }
      this.space = id;
      this.sourcePath = path;
      this.now = Date.now();
      this.busy = false;
      setShared(key, { snapshot, path, error, notice, readAt: this.now });
      if (canNotify) this.processNotifications(cx, key);
      cx.notify();
    });
  }

  /** @param {import('gpui-kit').Context} cx @param {string} key */
  processNotifications(cx, key) {
    const source = this.source(key), snapshot = source.snapshot;
    if (this.notificationBusy || source.error || !snapshot || snapshot.registration.fixture || Date.now() - source.readAt > 90000) return;
    this.notificationBusy = true;
    cx.spawn(async (cx) => {
      try {
        const notice = await this.notifyDecisions(snapshot);
        const latest = this.source(key);
        if (!latest.error && latest.snapshot?.registration.portfolio === snapshot.registration.portfolio && latest.notice !== notice) {
          setShared(key, { ...latest, notice });
          cx.notify();
        }
      } finally { this.notificationBusy = false; }
    });
  }

  /** @param {Snapshot} snapshot */
  async notifyDecisions(snapshot) {
    for (const decision of decisions(snapshot)) {
      const key = `work.notified.${decision.key}`;
      if (shared(key)) continue;
      // Reserve before exec: refresh/reopen cannot redeliver the same unresolved decision.
      setShared(key, "attempted");
      try {
        const result = await exec("notify-send", ["--app-name=Herdr Work", "--", `${decision.task} needs your decision`, decision.message], { timeout: 5000 });
        setShared(key, result.code === 0 ? "sent" : "failed");
      } catch { setShared(key, "failed"); }
    }
    return decisions(snapshot).some((d) => shared(`work.notified.${d.key}`) !== "sent") ? "Desktop notification failed or unconfirmed; decision remains here" : null;
  }

  toggle() {
    if (find(layout(), "panel-body")?.active === "work-progress" && !find(layout(), "panel")?.hidden) run("layout.hide", { id: "panel" });
    else { run("layout.select", { stack: "panel-body", child: "work-progress" }); run("layout.show", { id: "panel" }); }
  }

  expansionKey() {
    return `work.expansion.${spaces().find((s) => s.active)?.id ?? "unavailable"}`;
  }

  /** @returns {{ kind: "compact" } | { kind: "expanded", prior: number }} */
  expansion() {
    const value = shared(this.expansionKey());
    if (value && typeof value === "object" && "kind" in value && value.kind === "expanded" &&
      "prior" in value && typeof value.prior === "number" && Number.isFinite(value.prior) && value.prior >= 280 && value.prior <= 900) {
      return { kind: "expanded", prior: value.prior };
    }
    return { kind: "compact" };
  }

  panelWidth() {
    const size = find(layout(), "panel")?.size;
    if (size && typeof size === "object" && "px" in size && typeof size.px === "number" && Number.isFinite(size.px) && size.px > 0) return size.px;
    return this.width;
  }

  renderWidth() {
    return Math.max(0, Math.min(this.width, this.panelWidth()));
  }

  toggleExpand() {
    const state = this.expansion(), width = this.panelWidth();
    if (state.kind === "expanded") {
      setShared(this.expansionKey(), { kind: "compact" });
      run("layout.resize", { id: "panel", px: state.prior });
    } else if (width >= 720) {
      setShared(this.expansionKey(), { kind: "compact" });
      run("layout.resize", { id: "panel", px: 480 });
    } else {
      setShared(this.expansionKey(), { kind: "expanded", prior: width });
      run("layout.resize", { id: "panel", px: Math.min(880, Math.max(720, width + 240)) });
    }
  }

  /** @param {string} terminal */
  navigate(terminal) {
    const address = controllerTerminal(terminal, spaces().find((s) => s.active)?.machine);
    const pane = observedTerminals(terminals()).find((t) => t.address === address && t.state === "live");
    if (pane) run("agent.focus", { terminal: address });
  }

  /** @param {string} id @param {string} label @param {(cx: import('gpui-kit').Context) => void} action @param {boolean} selected */
  button(id, label, action, selected = false) {
    const t = palette();
    return Button.new(id).child(label).accessibility_label(label).text_size(12).min_h(32).px(8).py(4).rounded(2)
      .border(1).border_color(selected ? t.accent : t.border).bg(selected ? tint(t.accent) : t.surface)
      .text_color(t.foreground).hover((s) => s.bg(t.hover)).on_click((_e, cx) => action(cx));
  }

  /** @param {string} id @param {string} label @param {string} icon @param {(cx: import('gpui-kit').Context) => void} action */
  iconButton(id, label, icon, action) {
    const t = palette();
    return Button.new(id).size(32).flex_none().border(1).border_color(t.border).rounded(2)
      .accessibility_label(label).tooltip(label).text_color(t.muted).hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => action(cx)).child(svg(`mods/work/${icon}.svg`).size(16));
  }

  /** @param {string} label @param {string} value @param {import('gpui-kit').Color | undefined} color */
  line(label, value, color = undefined) {
    const t = palette();
    return v_flex().gap(4).child(div().text_size(11).text_color(t.muted).child(label))
      .child(div().text_size(12).text_color(color ?? t.foreground).child(value));
  }

  /** @param {string} label @param {string} value @param {string} explanation @param {import('gpui-kit').Color} color */
  summaryCell(label, value, explanation, color) {
    const t = palette();
    return v_flex().flex_1().min_w(0).gap(4).tooltip(explanation).accessibility_label(`${label}: ${value}. ${explanation}`)
      .child(div().text_size(10).text_color(t.muted).child(label))
      .child(div().text_size(12).text_color(color).truncate().child(value));
  }

  /** @param {Task} task @param {number} now */
  summary(task, now) {
    const t = palette();
    const blockers = task.issues.filter((i) => !i.resolved);
    const verified = task.last_verified;
    const checkIn = task.check_in;
    const status = freshness(task, now);
    return v_flex().w_full().min_w(0).border(1).border_color(t.border).p(12).gap(8)
      .child(h_flex().min_w(0).gap(8).items_center()
        .child(div().flex_1().min_w(0).font_semibold().truncate().tooltip(task.outcome).child(`${task.id} · ${task.outcome}`))
        .child(div().flex_none().border(1).border_color(t.border).px(8).py(4).text_size(10).accessibility_label(`${task.id} · ${task.state}`).child(task.state)))
      .child(h_flex().gap(16)
        .child(this.summaryCell("Current step", task.current.find((c) => c.id === task.step)?.title ?? task.step, checkIn?.summary ?? task.step, t.foreground))
        .child(this.summaryCell("Latest verified", verified ? `${age(verified.at, now)} · ${verified.summary}` : "None recorded", verified ? `${verified.checkpoint}: ${verified.summary} · ${verified.at}` : "No checkpoint acceptance recorded", t.foreground)))
      .child(h_flex().gap(16)
        .child(this.summaryCell(checkIn?.quiet_reason ? "Check-in · declared quiet" : "Check-in", checkIn && task.state === "active" ? deadline(checkIn.due, now) : status, checkIn ? `${checkIn.due} · ${status} · ${checkIn.summary}${checkIn.quiet_reason ? ` · ${checkIn.quiet_reason}` : ""}` : status, status === "Needs checking" ? t.blocked : t.foreground))
        .child(this.summaryCell(`Blockers${blockers.length ? ` (${blockers.length})` : ""}`, blockers.length ? `${blockers[0].needs_user ? "Decision: " : ""}${blockers[0].message}` : "None declared", blockers.map((i) => i.message).join(" · ") || "No explicit blockers", blockers.length ? t.blocked : t.muted)))
      .child(this.summaryCell("Next action", task.next_action, task.next_action, t.foreground).flex_none());
  }

  /** @param {Task} task @param {import('gpui-kit').Context} cx */
  map(task, cx) {
    const t = palette();
    const colors = { Complete: t.done, Active: t.working, Blocked: t.blocked, Upcoming: t.dim };
    return v_flex().w_full().min_w(0).gap(8).children(task.current.map((cp) => {
      const state = checkpointState(task, cp), selected = this.selection === `cp:${cp.id}`;
      return Button.new(`checkpoint-${cp.id}`).w_full().min_w(0).min_h(48).p(8).border(1)
        .border_color(selected ? t.accent : t.border).rounded(2).text_left().flex().items_center().justify_start()
        .bg(selected ? tint(t.accent) : t.surface).hover((s) => s.bg(t.hover))
        .accessibility_label(`${cp.id}: ${cp.title}; ${state}; depends on ${cp.depends.join(", ") || "none"}`)
        .on_click((_e, cx) => { this.selection = `cp:${cp.id}`; cx.notify(); })
        .child(h_flex().flex_1().min_w(0).gap(8).items_center()
          .child(div().size(12).flex_none().rounded(6).bg(colors[state]))
          .child(v_flex().flex_1().min_w(0).items_start().gap(4)
            .child(div().w_full().truncate().tooltip(cp.title).child(cp.title))
            .child(div().w_full().truncate().text_size(10).text_color(t.muted).tooltip(cp.acceptance).child(`${cp.id} · After ${cp.depends.join(", ") || "none"}`)))
          .child(div().flex_none().text_size(10).text_color(colors[state]).border(1).border_color(colors[state]).px(8).py(4).child(state)));
    }));
  }

  /** @param {Task} task @param {import('gpui-kit').Context} cx @param {number} availableWidth */
  chart(task, cx, availableWidth = this.renderWidth() - 32) {
    const t = palette();
    const available = Math.max(0, Math.min(availableWidth, this.renderWidth() - 32));
    if (available < 96) return div().w_full().min_w(0).text_color(t.muted).child("Widen Work to view history.");
    const frame = historyGeometry(task, available);
    const { width, height, left, right, start, end, x, y } = frame;
    const points = task.history;
    const scope = PathBuilder.stroke(1.5), verified = PathBuilder.stroke(2.5);
    for (const [i, point] of points.entries()) {
      if (i === 0) { scope.move_to(x(point.at), y(point.scope)); verified.move_to(x(point.at), y(point.verified)); }
      else { scope.line_to(x(point.at), y(points[i - 1].scope)).line_to(x(point.at), y(point.scope)); verified.line_to(x(point.at), y(points[i - 1].verified)).line_to(x(point.at), y(point.verified)); }
    }
    const last = points[points.length - 1];
    if (last) { scope.line_to(right, y(last.scope)); verified.line_to(right, y(last.verified)); }
    const baseline = PathBuilder.stroke(1.5).dash_array([5, 4]).move_to(left, y(task.baseline?.checkpoints.length ?? 0)).line_to(right, y(task.baseline?.checkpoints.length ?? 0));
    return v_flex().w_full().min_w(0).gap(8)
      .child(div().relative().w(width).min_w(0).h(height).bg(t.surface).border(1).border_color(t.border)
        .accessibility_label(`History: original ${task.baseline?.checkpoints.length ?? 0}, current scope ${task.current.length}, verified ${task.current.filter((c) => c.verification).length}. Integer checkpoint counts; select events below.`)
        .children(frame.ticks.map((tick) => window.paint_path(PathBuilder.stroke(1).move_to(left, tick.y).line_to(right, tick.y).build(), Background.solid(t.border).opacity(0.5)).absolute().size_full()))
        .children(frame.ticks.map((tick) => div().absolute().left(0).top(tick.y - 6).w(24).h(12).text_right().text_size(10).text_color(t.muted).child(`${tick.value}`)))
        .children(points.filter((p) => p.kind === "revise").map((p) => div().absolute().left(x(p.at)).top(frame.top).w(1).h(frame.bottom - frame.top).bg(t.blocked)))
        .child(window.paint_path(scope.build(), t.accent).absolute().size_full())
        .child(window.paint_path(verified.build(), t.done).absolute().size_full())
        .child(window.paint_path(baseline.build(), t.muted).absolute().size_full()))
      .child(h_flex().justify_between().text_size(10).text_color(t.muted)
        .child(div().tooltip(new Date(start).toISOString()).child(time(new Date(start).toISOString())))
        .child(div().tooltip(new Date(end).toISOString()).child(time(new Date(end).toISOString()))))
      .child(h_flex().gap(8).flex_wrap().text_size(10)
        .child(div().text_color(t.done).child("━ Verified"))
        .child(div().text_color(t.accent).child("━ Current scope"))
        .child(div().text_color(t.muted).child(`┄ Original ${task.baseline?.checkpoints.length ?? 0}`))
        .child(div().text_color(t.blocked).child("│ Revision")))
      .child(h_flex().gap(4).flex_wrap().children(points.slice(-12).map((p) =>
        this.button(`history-${p.event}`, `${p.kind} · ${p.verified}/${p.scope}`, (cx) => { this.selection = `event:${p.event}`; cx.notify(); }, this.selection === `event:${p.event}`))))
      .child(h_flex().gap(4).flex_wrap()
        .child(this.button("original-baseline", "Original baseline", (cx) => { this.selection = "baseline"; cx.notify(); }, this.selection === "baseline"))
        .children(task.revisions.filter((r) => r.event !== task.baseline?.event).map((r, i) =>
          this.button(`revision-${r.event}`, `Revision ${task.revisions_omitted + i + 1}`, (cx) => { this.selection = `revision:${r.event}`; cx.notify(); }, this.selection === `revision:${r.event}`))))
      .when(points.length > 12 || task.history_omitted > 0, (el) => el.child(div().text_size(10).text_color(t.muted).child("Recent event controls shown; full ordered history remains on disk.")));
  }

  /** Discrete reports on a shared time axis; the track does not encode duration.
   * @param {Task} task @param {string} terminal */
  activityStrip(task, terminal) {
    const t = palette();
    const width = Math.max(0, this.renderWidth() - 32), height = 32;
    if (width < 32) return div().w_full().min_w(0).text_color(t.muted).child("Widen Work to view report samples.");
    const now = Date.now();
    const { reports, start, end, x } = activityGeometry(task, width, now);
    const samples = reports.filter((a) => a.terminal === terminal);
    const colors = { working: t.working, idle: t.dim, blocked: t.blocked, done: t.done, unavailable: t.muted };
    const symbols = { working: "W", idle: "I", blocked: "!", done: "D", unavailable: "?" };
    const axis = PathBuilder.stroke(1).move_to(16, height / 2).line_to(width - 16, height / 2).build();
    return v_flex().w_full().min_w(0).gap(4)
      .child(div().relative().w(width).min_w(0).h(height).bg(t.surface).rounded(4)
        .accessibility_label(`${terminal}: ${samples.length} reported samples, ${new Date(start).toISOString()} to ${new Date(end).toISOString()}. Discrete reports only; no continuous activity or durations inferred.`)
        .child(window.paint_path(axis, t.border).absolute().size_full())
        .children(samples.map((sample) => {
          return Button.new(`activity-point-${sample.event}`).absolute().left(x(sample.at) - 16).top(0).size(32).flex().items_center().justify_center()
            .accessibility_label(`${terminal} reported ${sample.status} at ${sample.at}. ${sample.summary}. Inspect report.`)
            .tooltip(`${sample.status} · ${time(sample.at)} · ${sample.at}`)
            .on_click((_e, cx) => { this.selection = `activity:${sample.event}`; cx.notify(); })
            .child(div().size(16).flex().items_center().justify_center().border(1).border_color(colors[sample.status]).text_color(colors[sample.status])
              .bg(this.selection === `activity:${sample.event}` ? tint(t.accent) : t.surface).text_size(10).child(symbols[sample.status]));
        })))
      .child(h_flex().justify_between().text_size(10).text_color(t.muted)
        .child(div().tooltip(new Date(start).toISOString()).child(time(new Date(start).toISOString())))
        .child(div().tooltip(new Date(end).toISOString()).child(`${end === now ? "Now" : "Latest"} ${time(new Date(end).toISOString())}`)));
  }

  /** @param {Task} task @param {import('gpui-kit').Context} cx */
  inspector(task, cx) {
    const t = palette();
    const details = inspection(task, this.selection);
    return v_flex().p(8).gap(8).bg(t.raised).rounded(4)
      .children(details.lines.map((line) => v_flex().gap(4).child(this.line(line.label, line.value))
        .children(line.evidence.map((ref) => div().text_size(11).text_color(t.accent).child(ref)))))
      .when(details.terminal !== null, (el) => el.child(this.button("activity-open-worker", `Open worker ${details.terminal}`, () => {
        if (details.terminal) this.navigate(details.terminal);
      })));
  }

  /** @param {import('gpui-kit').Context} cx */
  render(cx) {
    const t = palette(), now = Date.now();
    const space = spaces().find((s) => s.active);
    const fixturePath = typeof props()?.source === "string" ? props().source : null;
    const id = fixturePath ? `fixture:${fixturePath}` : space?.id;
    if (id && this.requestedSpace !== id) {
      this.requestedSpace = id;
      cx.timer.after(0, (cx) => this.refresh(cx));
    }
    const source = this.source(`work.source.${id}`), snapshot = source.snapshot;
    const staleSource = source.readAt > 0 && now - source.readAt > 90000;
    const observed = observedTerminals(terminals());
    const coordinator = snapshot ? observed.find((o) => o.address === controllerTerminal(snapshot.registration.coordinator, space?.machine) && o.state === "live") : null;
    const hostUnavailable = space && machines().some((m) => m.name === space.machine && m.layout !== "ready");
    const fixtureCoordinator = snapshot?.registration.fixture && props()?.fixtureCoordinator === "idle";
    const coordinatorText = snapshot ? snapshot.registration.fixture ? `Fixture coordinator ${fixtureCoordinator ? "idle (recovered)" : "unavailable"}` : hostUnavailable ? "Coordinator connection unavailable" : coordinator ? `Coordinator ${coordinator.status}` : "Coordinator unavailable" : "Coordinator unknown";
    if (props()?.compact === true) {
      const label = source.error || staleSource ? "Work · source unavailable" : snapshot ? compactText(snapshot, now) : "Work · no source";
      return Button.new("work-compact").size_full().px(8).text_size(11).bg(t.chrome).text_color(source.error || staleSource ? t.blocked : t.muted)
        .accessibility_label(`${label}. ${coordinatorText}. Open Work panel`).hover((s) => s.bg(t.hover)).on_click(() => this.toggle()).child(`${label}${snapshot && !coordinator ? " · coordinator absent" : ""}`);
    }
    const root = v_flex().id("work-root").size_full().min_w(0).bg(t.surface).text_color(t.foreground).text_size(12)
      .when(this.handle !== null, (el) => this.handle ? el.track_focus(this.handle) : el).on_key_down((e) => { if (e.keystroke === "escape") run("pane.go", { direction: "left" }); })
      .on_size_change((size, cx) => { if (Math.abs(this.width - size.width) > 1) { this.width = size.width; cx.notify(); } });
    const expansion = this.expansion(), wide = this.panelWidth() >= 720;
    const header = h_flex().h(40).flex_none().px(8).gap(8).items_center().border_b(1).border_color(t.border)
      .child(div().flex_1().font_semibold().child("Work"))
      .child(this.iconButton("work-refresh", "Refresh Work", "refresh", (cx) => this.refresh(cx, true)))
      .child(this.iconButton("work-expand", expansion.kind === "expanded" ? "Restore Work width" : wide ? "Collapse Work" : "Expand Work", expansion.kind === "expanded" || wide ? "collapse" : "expand", () => this.toggleExpand()))
      .child(this.iconButton("work-close", "Close Work", "close", () => run("layout.hide", { id: "panel" })));
    root.child(header);
    const content = v_flex().id("work-scroll").flex_1().min_h(0).overflow_y_scrollbar().p(16).gap(8);
    if (snapshot?.registration.fixture) content.child(div().text_color(t.blocked).font_semibold().child("ISOLATED FIXTURE · never live portfolio work"));
    if (source.error || staleSource) content.child(this.line("Source unavailable · retained history only", source.error ?? "Reader has not refreshed for over 90 seconds", t.blocked));
    if (source.notice) content.child(div().text_color(t.blocked).child(source.notice));
    if (!snapshot) {
      content.child(div().text_color(t.muted).child(source.error ? "No valid saved snapshot is available." : "No Work source. Initialize this space with chief-of-staff-init."));
      return root.child(content);
    }
    content.child(h_flex().gap(8).justify_between().child(div().text_color(coordinator ? t.muted : t.blocked).child(coordinatorText))
      .child(this.button("work-coordinator", "Open coordinator", () => this.navigate(snapshot.registration.coordinator))));
    if (snapshot.tasks_omitted || snapshot.legacy_omitted) content.child(div().text_color(t.blocked).child(`Bounded view: ${snapshot.tasks_omitted} tasks and ${snapshot.legacy_omitted} legacy tasks omitted. Full records: ${snapshot.registration.portfolio}`));
    if (snapshot.legacy.length) content.child(div().text_color(t.muted).child(`No baseline (legacy): ${snapshot.legacy.join(", ")}`));
    if (snapshot.tasks.length > 1) content.child(h_flex().gap(4).flex_wrap().children(snapshot.tasks.map((task) => this.button(`task-${task.id}`, `${task.id} · ${task.state}`, (cx) => {
      this.selectedTask = task.id; this.selection = null; setShared(`work.task.${id}`, task.id); cx.notify();
    }, task.id === (this.selectedTask ?? shared(`work.task.${id}`) ?? snapshot.tasks[0]?.id)))));
    const savedTask = shared(`work.task.${id}`);
    const task = snapshot.tasks.find((task) => task.id === (this.selectedTask ?? savedTask)) ?? snapshot.tasks[0];
    if (!task) return root.child(content);
    content.child(this.summary(task, now));
    if (task.issues_omitted || task.history_omitted || task.activity_omitted || task.revisions_omitted) content.child(div().text_size(11).text_color(t.muted).child(`Bounded history: ${task.issues_omitted} resolved issues, ${task.history_omitted} chart events, ${task.activity_omitted} reports and ${task.revisions_omitted} plans omitted. Full history remains on disk; unresolved issues and latest worker reports are retained.`));
    if (task.workers_incomplete) content.child(div().text_size(11).text_color(t.blocked).child("Older snapshot has an incomplete worker roster. Coordinator can repair it from durable events."));
    if (task.baseline) {
      const width = this.renderWidth(), expanded = width >= 880;
      const plotWidth = expanded ? (width - 48) / 2 : width - 32;
      const checkpointColumn = v_flex().flex_1().min_w(0).gap(8)
        .child(div().font_semibold().child(`Checkpoints · ${task.current.filter((c) => c.verification).length} verified / ${task.current.length}`))
        .child(this.map(task, cx));
      const historyColumn = v_flex().flex_1().min_w(0).gap(8)
        .child(div().font_semibold().child("Verified completion and scope"))
        .child(this.chart(task, cx, plotWidth));
      content.child((expanded ? h_flex().items_start() : v_flex()).w_full().min_w(0).gap(16)
        .child(checkpointColumn).child(historyColumn));
    } else content.child(div().text_color(t.blocked).child("No baseline published. Checkpoint progress is unknown."));
    content.child(div().font_semibold().child("Worker activity · separate from verified progress"))
      .child(div().text_size(11).text_color(t.muted).child("Reported samples only · W working · I idle · ! blocked · D done · ? unavailable. Track is a time axis; gaps are unknown."));
    const workers = task.workers;
    content.child(v_flex().gap(8).children(workers.map((latest) => {
      const terminal = latest.terminal;
      const live = observed.find((o) => o.address === controllerTerminal(terminal, space?.machine) && o.state === "live");
      const color = live?.status === "working" ? t.working : live?.status === "blocked" ? t.blocked : live?.status === "done" ? t.done : t.dim;
      const row = Button.new(`worker-${terminal}`).w_full().min_w(0).min_h(48).p(8).border(1).border_color(t.border)
        .flex().items_center().justify_start().text_left().hover((s) => s.bg(t.hover))
        .accessibility_label(`${terminal} · observed ${live?.status ?? "unavailable"}. Latest report ${latest.status} ${age(latest.at, now)}. Open worker.`)
        .on_click(() => this.navigate(terminal))
        .child(h_flex().flex_1().min_w(0).gap(8).items_center()
          .child(div().size(8).flex_none().rounded(4).bg(color))
          .child(v_flex().flex_1().min_w(0).items_start().gap(4)
            .child(div().w_full().truncate().tooltip(terminal).child(terminal))
            .child(div().w_full().truncate().text_size(10).text_color(t.muted).tooltip(`${latest.summary} · ${latest.at}`).child(`Reported ${latest.status} · ${age(latest.at, now)}`)))
          .child(div().flex_none().border(1).border_color(color).text_color(color).text_size(10).px(8).py(4).child(`Observed ${live?.status ?? "unavailable"}`)));
      return v_flex().w_full().min_w(0).gap(4).child(row).child(this.activityStrip(task, terminal));
    })))
      .child(h_flex().gap(4).flex_wrap().children(task.activity.slice(-24).map((a) => this.button(`activity-${a.event}`, `${a.terminal} ${a.status}`, (cx) => { this.selection = `activity:${a.event}`; cx.notify(); }))))
      .when(!workers.length, (el) => el.child(div().text_color(t.muted).child("No worker reports recorded.")))
      .child(this.inspector(task, cx))
      .child(div().text_size(10).text_color(t.muted).tooltip(snapshot.published_at).child(`Saved #${snapshot.seq} · record ${age(snapshot.published_at, now)} · read ${age(new Date(source.readAt).toISOString(), now)}`))
      .child(div().w_full().min_w(0).truncate().text_size(10).text_color(t.dim).tooltip(source.path ?? "Source unknown").child(source.path ?? "Source unknown"))
      .child(div().text_size(10).text_color(t.dim).child("Read-only · visibility never resumes work"));
    return root.child(content);
  }
}
