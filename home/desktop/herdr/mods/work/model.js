// @ts-check

/** @param {unknown} value @returns {Record<string, unknown>} */
function object(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw Error("Expected an object");
  return Object.fromEntries(Object.entries(value));
}
/** @param {unknown} value */
function string(value) {
  if (typeof value !== "string" || !value || value.length > 2000) throw Error("Invalid text");
  return value;
}
/** @param {unknown} value */
function number(value) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw Error("Invalid count");
  return value;
}
/** @param {unknown} value */
function timestamp(value) {
  const result = string(value);
  if (!Number.isFinite(Date.parse(result))) throw Error("Invalid timestamp");
  return result;
}
/** @param {unknown} value @returns {unknown[]} */
function array(value) {
  if (!Array.isArray(value)) throw Error("Invalid list");
  return value;
}
/** @template {string} T @param {unknown} value @param {readonly T[]} choices @returns {T} */
function choice(value, choices) {
  for (const item of choices) if (value === item) return item;
  throw Error("Unknown state");
}
/** @param {unknown} value */
function verification(value) {
  const v = object(value);
  return { event: string(v.event), at: timestamp(v.at), summary: string(v.summary), evidence: array(v.evidence).map(string) };
}
/** @param {unknown} value */
function definition(value) {
  const v = object(value);
  return { id: string(v.id), title: string(v.title), acceptance: string(v.acceptance), depends: array(v.depends).map(string) };
}
/** @param {unknown} value */
function report(value) {
  const a = object(value);
  return { event: string(a.event), at: timestamp(a.at), terminal: string(a.terminal), status: choice(a.status, ["working", "idle", "blocked", "done", "unavailable"]), summary: string(a.summary) };
}
/** @param {unknown} value */
function task(value) {
  const v = object(value);
  const baseline = v.baseline === null ? null : object(v.baseline);
  const checkIn = v.check_in === null ? null : object(v.check_in);
  const last = v.last_verified === null ? null : object(v.last_verified);
  const activity = array(v.activity).map(report);
  const workers = v.workers === undefined ? [...new Map(activity.map((a) => [a.terminal, a])).values()] : array(v.workers).map(report);
  if (new Set(workers.map((w) => w.terminal)).size !== workers.length) throw Error("Duplicate worker terminal");
  const current = array(v.current).map((value) => {
    const c = object(value);
    return { ...definition(c), version: number(c.version), verification: c.verification === null ? null : verification(c.verification) };
  });
  const ids = new Set(current.map((c) => c.id));
  if (ids.size !== current.length || current.some((c) => c.depends.some((id) => !ids.has(id)))) throw Error("Invalid checkpoint dependencies");
  return {
    id: string(v.id), outcome: string(v.outcome), state: choice(v.state, ["queued", "active", "paused", "cancelled", "done"]),
    next_action: string(v.next_action), step: string(v.step), updated_at: timestamp(v.updated_at),
    baseline: baseline === null ? null : { at: timestamp(baseline.at), event: baseline.event === undefined || baseline.event === null ? null : string(baseline.event), checkpoints: array(baseline.checkpoints).map(definition) },
    current,
    check_in: checkIn === null ? null : { at: timestamp(checkIn.at), due: timestamp(checkIn.due), summary: string(checkIn.summary), quiet_reason: checkIn.quiet_reason === null ? null : string(checkIn.quiet_reason) },
    last_verified: last === null ? null : { ...verification(last), checkpoint: string(last.checkpoint) },
    issues: array(v.issues).map((value) => {
      const i = object(value);
      if (typeof i.needs_user !== "boolean") throw Error("Invalid issue");
      const resolved = i.resolved === null ? null : object(i.resolved);
      return { id: string(i.id), at: timestamp(i.at), message: string(i.message), needs_user: i.needs_user,
        checkpoint: i.checkpoint === null ? null : string(i.checkpoint),
        resolved: resolved === null ? null : { at: timestamp(resolved.at), summary: string(resolved.summary) } };
    }),
    history: array(v.history).map((value) => {
      const h = object(value);
      const cp = h.checkpoint === undefined || h.checkpoint === null ? null : object(h.checkpoint);
      return { event: string(h.event), seq: number(h.seq), at: timestamp(h.at), kind: choice(h.kind, ["plan", "revise", "verify", "lifecycle"]), scope: number(h.scope), verified: number(h.verified), summary: string(h.summary),
        checkpoint: cp === null ? null : { ...definition(cp), version: number(cp.version), verification: verification(cp.verification) } };
    }),
    revisions: array(v.revisions).map((value) => {
      const r = object(value);
      return { event: string(r.event), at: timestamp(r.at), reason: string(r.reason), added: array(r.added).map(string), removed: array(r.removed).map(string), changed: array(r.changed).map(string), checkpoints: array(r.checkpoints).map(definition) };
    }),
    activity, workers, workers_incomplete: v.workers === undefined || v.workers_incomplete === true,
    issues_omitted: v.issues_omitted === undefined ? 0 : number(v.issues_omitted),
    history_omitted: number(v.history_omitted), revisions_omitted: number(v.revisions_omitted), activity_omitted: number(v.activity_omitted),
  };
}

/** Validate at the file boundary; corrupt data never becomes progress. @param {unknown} value */
export function parseSnapshot(value) {
  const v = object(value);
  if (v.version !== 1) throw Error("Unsupported Work record version");
  const r = object(v.registration);
  if (typeof r.fixture !== "boolean") throw Error("Invalid fixture marker");
  const tasks = array(v.tasks).map(task);
  if (new Set(tasks.map((t) => t.id)).size !== tasks.length) throw Error("Duplicate task ID");
  return { version: 1, seq: number(v.seq), published_at: timestamp(v.published_at), tasks,
    registration: { portfolio: string(r.portfolio), space: string(r.space), coordinator: string(r.coordinator), core: string(r.core), fixture: r.fixture },
    legacy: array(v.legacy).map(string), tasks_omitted: number(v.tasks_omitted), legacy_omitted: number(v.legacy_omitted) };
}

/** @typedef {ReturnType<typeof parseSnapshot>} Snapshot */
/** @typedef {Snapshot['tasks'][number]} Task */
/** @param {string | null | undefined} at @param {number} now */
export function age(at, now) {
  if (!at) return "never";
  const minutes = Math.max(0, Math.floor((now - Date.parse(at)) / 60000));
  return minutes < 1 ? "just now" : minutes < 60 ? `${minutes}m ago` : minutes < 1440 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m ago` : `${Math.floor(minutes / 1440)}d ago`;
}
/** @param {string} at */
export function time(at) {
  return new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
}
/** @param {string} due @param {number} now */
export function deadline(due, now) {
  const delta = Date.parse(due) - now;
  const minutes = Math.ceil(Math.abs(delta) / 60000);
  if (minutes === 0) return "Due now";
  const duration = minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h${minutes % 60 ? ` ${minutes % 60}m` : ""}`;
  return delta < 0 ? `${duration} overdue` : `Due in ${duration}`;
}
/** @param {Task} task @param {number} width */
export function historyGeometry(task, width) {
  const max = Math.max(1, task.baseline?.checkpoints.length ?? 0, ...task.history.map((p) => p.scope));
  const height = Math.max(144, (max + 1) * 16 + 24);
  const left = 32, right = width - 16, top = 12, bottom = height - 16;
  const start = Date.parse(task.baseline?.at ?? task.history[0]?.at ?? task.updated_at);
  const end = Math.max(start + 1, ...task.history.map((p) => Date.parse(p.at)));
  /** @param {number} value */ const y = (value) => bottom - value / max * (bottom - top);
  /** @param {string} at */ const x = (at) => left + (Date.parse(at) - start) / (end - start) * (right - left - 16);
  return { width, height, left, right, top, bottom, max, start, end, x, y,
    ticks: Array.from({ length: max + 1 }, (_, value) => ({ value, y: y(value) })) };
}
/** Latest reports are discrete samples; the neutral axis continues to the current clock.
 * @param {Task} task @param {number} width @param {number} now */
export function activityGeometry(task, width, now) {
  const reports = [...new Map([...task.activity, ...task.workers].map((a) => [a.event, a])).values()];
  const timestamps = reports.map((a) => Date.parse(a.at));
  const end = Math.max(now, ...timestamps), start = Math.min(end, ...timestamps);
  const span = Math.max(1, end - start);
  /** @param {string} at */ const x = (at) => 16 + (Date.parse(at) - start) / span * (width - 32);
  return { reports, start, end, x };
}
/** @param {Task} task @param {number} now */
export function freshness(task, now) {
  if (!task.baseline) return "No baseline";
  if (task.state !== "active") return task.state;
  if (!task.check_in) return "No check-in";
  return now > Date.parse(task.check_in.due) ? "Needs checking" : task.check_in.quiet_reason ? "Declared quiet window" : "Check-in current";
}
/** @param {Task} task @param {Task['current'][number]} cp */
export function checkpointState(task, cp) {
  if (cp.verification) return "Complete";
  if (task.issues.some((i) => !i.resolved && (i.checkpoint === null || i.checkpoint === cp.id))) return "Blocked";
  return task.step === cp.id && task.state === "active" ? "Active" : "Upcoming";
}
/** @param {Snapshot} snapshot */
export function decisions(snapshot) {
  return snapshot.tasks.flatMap((task) => task.issues.filter((i) => !i.resolved && i.needs_user).map((issue) => ({
    key: `${snapshot.registration.portfolio}/${task.id}/${issue.id}`, task: task.id, message: issue.message,
  })));
}

/** @typedef {{ label: string, value: string, evidence: string[] }} InspectionLine */
/** @param {Task['current'][number] | NonNullable<Task['baseline']>['checkpoints'][number]} cp @returns {InspectionLine} */
function criterion(cp) {
  return { label: `${cp.id} · ${cp.title}`, value: `${cp.acceptance} · Depends on ${cp.depends.join(", ") || "none"}`, evidence: [] };
}
/** Explanation data also serves the native inspector; definitions come from the selected historical version.
 * @param {Task} task @param {string | null} selection
 * @returns {{ lines: InspectionLine[], terminal: string | null }} */
export function inspection(task, selection) {
  if (selection === "baseline" && task.baseline) return { terminal: null, lines: [
    { label: `Original baseline · ${task.baseline.at}`, value: "Immutable original checkpoint criteria", evidence: [] },
    ...task.baseline.checkpoints.map(criterion),
  ] };
  const cp = task.current.find((c) => selection === `cp:${c.id}`);
  if (cp) return { terminal: null, lines: [criterion(cp), {
    label: `Version ${cp.version} · verification`, value: cp.verification ? `${cp.verification.summary} · ${cp.verification.at}` : "No accepted evidence yet", evidence: cp.verification?.evidence ?? [],
  }] };
  const event = task.history.find((h) => selection === `event:${h.event}`);
  const revision = task.revisions.find((r) => selection === `revision:${r.event}` || r.event === event?.event);
  if (revision) return { terminal: null, lines: [
    { label: `Plan · ${revision.at}`, value: revision.reason, evidence: [] },
    { label: "Scope change", value: `Added: ${revision.added.join(", ") || "none"}; removed: ${revision.removed.join(", ") || "none"}; changed: ${revision.changed.join(", ") || "none"}`, evidence: [] },
    ...revision.checkpoints.map(criterion),
  ] };
  if (event) {
    /** @type {InspectionLine[]} */
    const lines = [{ label: `${event.kind} · #${event.seq} · ${event.at}`, value: event.summary, evidence: [] }];
    if (event.checkpoint) lines.push(criterion(event.checkpoint), {
      label: `Accepted version ${event.checkpoint.version}`, value: event.checkpoint.verification.summary, evidence: event.checkpoint.verification.evidence,
    });
    else if (event.kind === "verify") lines.push({ label: "Historical evidence unavailable", value: "Older snapshot lacks verification details; coordinator can repair it from durable events", evidence: [] });
    else if (event.kind === "plan" && task.baseline) lines.push(...task.baseline.checkpoints.map(criterion));
    return { terminal: null, lines };
  }
  const activity = [...task.activity, ...task.workers].find((a) => selection === `activity:${a.event}`);
  if (activity) return { terminal: activity.terminal, lines: [{ label: `Worker report · ${activity.at}`, value: `${activity.terminal}: ${activity.status} · ${activity.summary}`, evidence: [] }] };
  return { terminal: null, lines: [{ label: "Evidence inspector", value: "Select a checkpoint, baseline, revision, history event or worker report", evidence: [] }] };
}

/** @param {Snapshot} snapshot @param {number} now */
export function compactText(snapshot, now) {
  const needs = decisions(snapshot).length;
  if (needs) return `Work · ${needs} decision${needs === 1 ? "" : "s"}`;
  const active = snapshot.tasks.filter((t) => t.state === "active");
  const stale = active.filter((t) => freshness(t, now) === "Needs checking").length;
  if (stale) return `Work · ${stale} needs checking`;
  const blocked = snapshot.tasks.filter((t) => t.issues.some((i) => !i.resolved)).length;
  if (blocked) return `Work · ${blocked} blocked`;
  if (active.length) return `Work · ${active.length} active · ${active.reduce((sum, t) => sum + t.current.filter((c) => c.verification).length, 0)} verified`;
  return snapshot.tasks.length ? "Work · no active tasks" : snapshot.legacy.length ? "Work · no baseline" : "Work · no tasks";
}

/** Unknown host terminals are narrowed once, outside presentation. @param {unknown} value */
export function observedTerminals(value) {
  return array(value).flatMap((value) => {
    const t = object(value);
    if (typeof t.address !== "string" || typeof t.state !== "string") return [];
    return [{ address: t.address, state: t.state,
      status: typeof t.status === "string" ? t.status : "unreported" }];
  });
}

/** @param {unknown} value */
export function parseSource(value) {
  const v = object(value);
  if (typeof v.readAt !== "number" || !Number.isFinite(v.readAt)) throw Error("Invalid source age");
  return { snapshot: v.snapshot === null ? null : parseSnapshot(v.snapshot), readAt: v.readAt,
    error: v.error === null ? null : string(v.error), path: v.path === null ? null : string(v.path),
    notice: v.notice === null ? null : string(v.notice) };
}
