import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import * as model from "../../../desktop/herdr/mods/work/model.js";
const { parseSnapshot, parseSource, freshness, decisions, compactText, checkpointState, inspection, deadline, time, historyGeometry, activityGeometry } = model;

function readFixture(name) {
  const fixtures = JSON.parse(readFileSync(process.argv[2], "utf8"));
  return parseSnapshot(JSON.parse(readFileSync(fixtures[name].source, "utf8")));
}

test("published fixtures retain decisions, stale clocks, scope and evidence across shared-state round trips", () => {
  assert.ok(process.argv[2], "Pass the generated scenarios.json path as the first argument");
  const fixtures = JSON.parse(readFileSync(process.argv[2], "utf8"));
    const load = (name) => parseSnapshot(JSON.parse(readFileSync(fixtures[name].source, "utf8")));
    const stale = load("stale");
    assert.equal(freshness(stale.tasks[0], Date.now()), "Needs checking");
    assert.match(compactText(stale, Date.now()), /needs checking/);
    assert.equal(stale.tasks[0].activity.at(-1).status, "working");
    assert.equal(freshness(load("quiet").tasks[0], Date.now()), "Declared quiet window");
    const blocked = load("blocker");
    const restored = parseSource(JSON.parse(JSON.stringify({ snapshot: blocked, path: fixtures.blocker.source, error: null, notice: null, readAt: Date.now() }))).snapshot;
    assert.deepEqual(restored, blocked);
    assert.equal(decisions(restored).length, 1);
    assert.equal(checkpointState(restored.tasks[0], restored.tasks[0].current[1]), "Blocked");
    assert.equal(checkpointState(restored.tasks[0], restored.tasks[0].current[0]), "Complete");
    const revised = load("revision").tasks[0];
    assert.equal(revised.baseline.checkpoints.length, 2);
    assert.equal(revised.current.length, 3);
    assert.equal(revised.current.filter((c) => c.verification).length, 1);
    assert.equal(revised.history.at(-1).kind, "revise");
    assert.throws(() => parseSnapshot({ ...stale, version: 99 }), /version/);
    assert.throws(() => parseSnapshot({ ...stale, tasks: [{ id: "partial" }] }));
});

test("writer-produced collections above 256 round-trip without losing pending decisions", () => {
  const snapshot = readFixture("collection-bounds");
  assert.equal(snapshot.tasks.length, 258);
  const task = snapshot.tasks.find((t) => t.id === "T001");
  assert.equal(task.issues.length, 321);
  assert.equal(task.issues_omitted, 193);
  assert.equal(decisions(snapshot).length, 257);
  assert.deepEqual(parseSnapshot(JSON.parse(JSON.stringify(snapshot))), snapshot);
});

test("older snapshots remain readable and disclose missing roster/evidence until repair", () => {
  const old = readFixture("history-evidence");
  for (const task of old.tasks) {
    delete task.workers;
    delete task.workers_incomplete;
    delete task.issues_omitted;
    if (task.baseline) delete task.baseline.event;
    for (const event of task.history) delete event.checkpoint;
  }
  const restored = parseSnapshot(old), task = restored.tasks[0];
  assert.equal(task.workers_incomplete, true);
  const verify = task.history.find((h) => h.kind === "verify");
  assert.match(JSON.stringify(inspection(task, `event:${verify.event}`)), /Historical evidence unavailable/);
  assert.deepEqual(parseSnapshot(JSON.parse(JSON.stringify(restored))), restored);
});

// Herdr/Wayland cannot run inside the worker sandbox. Exercise the real Work
// class with host I/O doubles; native rendering remains a coordinator check.
function viewHarness(snapshot, options = {}) {
  let compact = false, now = Date.now(), panelWidth = null, panelChild = "work-progress", panelHidden = false, notifications = 0;
  const state = new Map(), pending = [], executions = [], commands = [];
  const observed = options.terminals ?? [{ address: "tfixtureworker", state: "live", status: "working" }];
  function element(kind, id = null) {
    const node = { kind, id, children: [], consumed: false, click: null, label: null, styles: {} };
    const value = new Proxy({}, { get(_target, name) {
      if (name === "__node") return node;
      if (name === "then") return undefined;
      return (...args) => {
        assert.equal(node.consumed, false, `${kind} mutated after attachment`);
        const add = (child) => {
          if (child?.__node) {
            assert.equal(child.__node.consumed, false, "Element added twice");
            child.__node.consumed = true;
          }
          node.children.push(child);
        };
        if (name === "child") add(args[0]);
        if (name === "children") args[0].forEach(add);
        if (name === "id") node.id = args[0];
        if (name === "on_click") node.click = args[0];
        if (name === "accessibility_label") node.label = args[0];
        node.styles[name] = args.length ? args[0] : true;
        if (name === "when" && args[0]) return args[1](value);
        if (name === "build") return {};
        return value;
      };
    } });
    return value;
  }
  const source = readFileSync(new URL("../../../desktop/herdr/mods/work/main.js", import.meta.url), "utf8")
    .replace(/^import .*;\n/gm, "").replace("export default class Work", "class Work") + "\nWork;";
  const Work = runInNewContext(source, {
    ...model, View: class {}, Date: class extends Date { static now() { return now; } },
    div: () => element("div"), h_flex: () => element("h_flex"), v_flex: () => element("v_flex"),
    svg: () => element("svg"), Background: { solid: () => ({ opacity() { return {}; } }) },
    Button: { new: (id) => element("button", id) }, PathBuilder: { stroke: () => element("path") },
    window: { paint_path: () => element("paint_path") },
    spaces: () => [options.space ?? { id: snapshot.registration.space, active: true, machine: null }],
    props: () => ({ compact }), terminals: () => observed, machines: () => [],
    home: () => options.home ?? "/home/test",
    theme: () => ({ foreground: "#ffffff", surface: "#222222", border: "#555555", dim: "#777777", muted: "#888888", done: "#00ff00", accent: "#00ffff", working: "#0000ff", blocked: "#ff0000" }),
    layout: () => ({ children: [{ id: "panel", hidden: panelHidden, size: panelWidth === null ? undefined : { px: panelWidth } }, { id: "panel-body", active: panelChild }] }),
    shared: (key) => state.get(key), setShared: (key, value) => state.set(key, value),
    run: (name, args) => {
      commands.push({ name, args });
      if (name === "layout.resize" && args.id === "panel") panelWidth = args.px;
      if (name === "layout.select" && args.stack === "panel-body") panelChild = args.child;
      if (name === "layout.hide" && args.id === "panel") panelHidden = true;
      if (name === "layout.show" && args.id === "panel") panelHidden = false;
    },
    readTextFile: async () => JSON.stringify(snapshot),
    exec: async (command, args, settings) => {
      executions.push({ command, args, settings });
      if (options.exec) return options.exec(command, args, settings);
      return { code: 0, stdout: JSON.stringify({ snapshot: "/isolated/snapshot.json" }), stderr: "" };
    },
  });
  const cx = { notify() { notifications++; }, timer: { after() {} }, spawn(body) { pending.push(Promise.resolve(body(cx))); } };
  return {
    Work, state, cx, executions, commands,
    mode(value) { compact = value; }, advance(milliseconds = 30000) { now += milliseconds; },
    clock() { return now; }, notifications() { return notifications; }, panel(value) { panelWidth = value; },
    activePanel(value) { panelChild = value; },
    async drain() { while (pending.length) await Promise.all(pending.splice(0)); },
  };
}

test("GUI discovery loads its snapshot when PATH excludes the installed helper", async () => {
  const snapshot = readFixture("revision");
  snapshot.registration.fixture = false;
  const guiHome = mkdtempSync(join(tmpdir(), "herdr work home "));
  try {
    const directory = join(guiHome, ".local", "bin");
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "chief-of-staff-work"), `#!${process.execPath}\nif (process.argv.slice(2).join(" ") !== ${JSON.stringify(`locate --space ${snapshot.registration.space}`)}) process.exit(2);\nprocess.stdout.write(JSON.stringify({ snapshot: "/isolated/snapshot.json" }));\n`, { mode: 0o755 });
    const host = viewHarness(snapshot, {
      home: guiHome,
      exec: (command, args) => ({ code: 0, stdout: execFileSync(command, args, { encoding: "utf8", env: { PATH: "/nonexistent", HOME: guiHome } }), stderr: "" }),
    });
    host.mode(true);
    new host.Work().refresh(host.cx);
    await host.drain();
    const loaded = host.state.get(`work.source.${snapshot.registration.space}`);
    assert.equal(loaded.error, null);
    assert.equal(loaded.snapshot.seq, snapshot.seq);
    assert.equal(loaded.snapshot.registration.portfolio, snapshot.registration.portfolio);
  } finally {
    rmSync(guiHome, { recursive: true, force: true });
  }
});

for (const qualified of [true, false]) test(`remote discovery uses native IDs and preserves UI cache namespace (${qualified})`, async () => {
  const snapshot = readFixture("revision");
  snapshot.registration.fixture = false;
  const native = snapshot.registration.space, machine = "workstation-worker";
  const id = qualified ? `${machine}/${native}` : native;
  const host = viewHarness(snapshot, {
    space: { id, active: true, machine },
    exec: (command, args, settings) => {
      assert.equal(command, "chief-of-staff-work");
      assert.equal(settings.on, machine);
      return { code: args[2] === native ? 0 : 2, stdout: JSON.stringify({ snapshot: "/remote/snapshot.json" }), stderr: "" };
    },
  });
  host.mode(true);
  new host.Work().refresh(host.cx);
  await host.drain();
  const loaded = host.state.get(`work.source.${id}`);
  assert.equal(loaded.error, null);
  assert.equal(loaded.snapshot.registration.space, native);
  assert.equal(loaded.snapshot.seq, snapshot.seq);
  assert.equal(host.executions.length, 1);
  assert.equal(host.executions[0].args[2], native);
  if (qualified) assert.equal(host.state.has(`work.source.${native}`), false);
});

test("remote discovery still rejects another native space's snapshot", async () => {
  const snapshot = readFixture("revision");
  snapshot.registration.fixture = false;
  const id = "workstation-worker/sp-other";
  const host = viewHarness(snapshot, { space: { id, active: true, machine: "workstation-worker" } });
  host.mode(true);
  new host.Work().refresh(host.cx);
  await host.drain();
  assert.match(host.state.get(`work.source.${id}`).error, /different space/);
});

function textContent(value) {
  if (value?.__node) return value.__node.children.map(textContent).join("\n");
  return typeof value === "string" ? value : "";
}
function findElement(value, id) {
  if (!value?.__node) return null;
  if (value.__node.id === id) return value.__node;
  for (const child of value.__node.children) { const found = findElement(child, id); if (found) return found; }
  return null;
}

function findNode(value, predicate) {
  if (!value?.__node) return null;
  if (predicate(value.__node)) return value.__node;
  for (const child of value.__node.children) { const found = findNode(child, predicate); if (found) return found; }
  return null;
}

test("remote coordinator and worker controls use their machine-qualified terminal addresses", () => {
  const snapshot = readFixture("worker-roster");
  snapshot.registration.fixture = false;
  const machine = "workstation-worker", id = `${machine}/${snapshot.registration.space}`;
  const coordinator = snapshot.registration.coordinator, worker = "tfixtureworker";
  const host = viewHarness(snapshot, {
    space: { id, active: true, machine },
    terminals: [
      { address: coordinator, state: "live", status: "idle" },
      { address: `other/${coordinator}`, state: "live", status: "blocked" },
      { address: `${machine}/${coordinator}`, state: "live", status: "working" },
      { address: worker, state: "live", status: "idle" },
      { address: `${machine}/${worker}`, state: "live", status: "working" },
    ],
  });
  host.state.set(`work.source.${id}`, { snapshot, path: "/remote/snapshot.json", readAt: host.clock(), error: null, notice: null });
  const view = new host.Work(), root = view.render(host.cx);
  assert.match(textContent(root), /Coordinator working/);
  findElement(root, "work-coordinator").click({}, host.cx);
  assert.equal(host.commands.at(-1).args.terminal, `${machine}/${coordinator}`);
  const row = findElement(root, `worker-${worker}`);
  assert.match(row.label, /observed working/);
  row.click({}, host.cx);
  assert.equal(host.commands.at(-1).args.terminal, `${machine}/${worker}`);
  view.navigate(`${machine}/${worker}`);
  assert.equal(host.commands.at(-1).args.terminal, `${machine}/${worker}`);
});

test("remote navigation never falls back to matching local or other-machine terminal IDs", () => {
  const snapshot = readFixture("revision");
  snapshot.registration.fixture = false;
  const coordinator = snapshot.registration.coordinator, machine = "workstation-worker";
  const id = `${machine}/${snapshot.registration.space}`;
  const host = viewHarness(snapshot, {
    space: { id, active: true, machine },
    terminals: [{ address: coordinator, state: "live", status: "working" },
                { address: `other/${coordinator}`, state: "live", status: "working" }],
  });
  host.state.set(`work.source.${id}`, { snapshot, path: "/remote/snapshot.json", readAt: host.clock(), error: null, notice: null });
  const view = new host.Work(), root = view.render(host.cx);
  assert.match(textContent(root), /Coordinator unavailable/);
  findElement(root, "work-coordinator").click({}, host.cx);
  assert.equal(host.commands.length, 0);
});

for (const scenario of [
  { name: "pending shrink", measured: 720, host: 480 },
  { name: "pending expansion", measured: 480, host: 720 },
  { name: "settled 720", measured: 720, host: 720 },
  { name: "pending 880 expansion", measured: 720, host: 880 },
  { name: "pending 720 shrink", measured: 880, host: 720 },
  { name: "settled 880", measured: 880, host: 880 },
  { name: "minimum panel", measured: 720, host: 280 },
  { name: "remounted shrink", measured: 400, host: 480, remount: true },
  { name: "remounted expansion", measured: 400, host: 720, remount: true },
]) test(`resize premise: ${scenario.name} (${scenario.measured}/${scenario.host})`, () => {
  const snapshot = readFixture("revision"), host = viewHarness(snapshot);
  host.state.set(`work.source.${snapshot.registration.space}`, { snapshot, path: "/fixture/snapshot.json", readAt: host.clock(), error: null, notice: null });
  host.panel(scenario.host);
  let view = new host.Work();
  if (scenario.remount) { view.width = 720; view.render(host.cx); view = new host.Work(); }
  view.width = scenario.measured;
  const root = view.render(host.cx);
  const columns = findNode(root, (n) => n.children.length === 2 &&
    textContent(n.children[0]).startsWith("Checkpoints ·") && textContent(n.children[1]).startsWith("Verified completion and scope"));
  const history = findNode(root, (n) => n.label?.startsWith("History:"));
  const strip = findNode(root, (n) => n.label?.startsWith("tfixtureworker:"));
  assert.ok(columns); assert.ok(history); assert.ok(strip);
  const bounded = Math.min(scenario.measured, scenario.host);
  const plotLimit = columns.kind === "h_flex" ? (bounded - 48) / 2 : bounded - 32;
  const problems = [];
  if (history.styles.w > plotLimit) problems.push(`history width ${history.styles.w} exceeds its ${plotLimit}px live column`);
  if (strip.styles.w > bounded - 32) problems.push(`worker strip width ${strip.styles.w} exceeds ${bounded - 32}px live content`);
  if (columns.kind !== (bounded >= 880 ? "h_flex" : "v_flex")) problems.push(`breakpoint chose ${columns.kind} at ${bounded}px`);
  assert.deepEqual(problems, []);
});

for (const name of ["main-flat", "main-preview"]) test(`layout IDs stay unique and preserve existing panels: ${name}`, () => {
  const layout = JSON.parse(readFileSync(new URL(`../../../desktop/herdr/layouts/${name}.json`, import.meta.url), "utf8"));
  const nodes = [];
  function visit(node) { nodes.push(node); for (const child of node.children ?? []) visit(child); }
  visit(layout);
  const ids = nodes.map((n) => n.id).filter(Boolean);
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(nodes.find((n) => n.id === "work").type, "column");
  const stack = nodes.find((n) => n.id === "panel-body");
  assert.deepEqual(stack.children.map((n) => n.id), ["files", "changes", "preview", "costs", "work-progress"]);
  assert.equal(stack.children.find((n) => n.id === "work-progress").content.mod, "work");
});

test("work panel toggle targets only the unique Work stack child", () => {
  const host = viewHarness(readFixture("revision")), view = new host.Work();
  host.activePanel("files");
  view.toggle();
  assert.equal(host.commands[0].name, "layout.select");
  assert.equal(host.commands[0].args.stack, "panel-body");
  assert.equal(host.commands[0].args.child, "work-progress");
  assert.equal(host.commands[1].name, "layout.show");
  assert.equal(host.commands[1].args.id, "panel");
  view.toggle();
  assert.equal(host.commands.at(-1).name, "layout.hide");
  assert.equal(host.commands.at(-1).args.id, "panel");
});

test("full panel refresh cannot starve compact cached decision notifications", async () => {
  const snapshot = readFixture("blocker");
  snapshot.registration.fixture = false; // Host-I/O test only; no real process runs.
  const host = viewHarness(snapshot), panel = new host.Work(), compact = new host.Work();
  for (let cycle = 0; cycle < 3; cycle++) {
    host.mode(false); panel.refresh(host.cx); await host.drain();
    const readAt = host.state.get(`work.source.${snapshot.registration.space}`).readAt;
    host.mode(true); compact.refresh(host.cx); await host.drain();
    assert.equal(host.state.get(`work.source.${snapshot.registration.space}`).readAt, readAt);
    host.advance();
  }
  assert.equal(host.executions.filter((e) => e.command === "notify-send").length, 1);
  const reopened = new host.Work();
  host.mode(true); reopened.refresh(host.cx); await host.drain();
  assert.equal(host.executions.filter((e) => e.command === "notify-send").length, 1);
});

test("native inspector description exposes baseline, superseded criteria and removed verification proof", () => {
  const snapshot = readFixture("history-evidence"), task = snapshot.tasks[0];
  assert.match(JSON.stringify(inspection(task, "baseline")), /Original removed criterion/);
  const earlier = task.revisions.find((r) => r.reason.startsWith("Remove obsolete"));
  assert.match(JSON.stringify(inspection(task, `revision:${earlier.event}`)), /First revised native criterion/);
  const verified = task.history.find((h) => h.checkpoint?.id === "obsolete");
  const details = JSON.stringify(inspection(task, `event:${verified.event}`));
  assert.match(details, /Original removed criterion/);
  assert.match(details, /removed checkpoint proof/);
  const host = viewHarness(snapshot), view = new host.Work();
  view.selection = `event:${verified.event}`;
  assert.match(textContent(view.inspector(task, host.cx)), /removed checkpoint proof/);
  view.selection = `revision:${earlier.event}`;
  assert.match(textContent(view.inspector(task, host.cx)), /First revised native criterion/);
});

test("bounded reports retain a live worker row, timestamp point, evidence and navigation", () => {
  const snapshot = readFixture("worker-roster"), task = snapshot.tasks[0];
  assert.equal(task.activity.length, 64);
  assert.equal(task.activity.some((a) => a.terminal === "tfixtureworker"), false);
  assert.equal(task.workers.length, 2);
  const host = viewHarness(snapshot), view = new host.Work();
  host.state.set(`work.source.${snapshot.registration.space}`, { snapshot, path: "/fixture/snapshot.json", readAt: Date.now(), error: null, notice: null });
  const root = view.render(host.cx);
  const worker = findElement(root, "worker-tfixtureworker");
  assert.ok(worker);
  assert.match(worker.label, /tfixtureworker · observed working/);
  worker.click({}, host.cx);
  assert.equal(host.commands.at(-1).name, "agent.focus");
  assert.equal(host.commands.at(-1).args.terminal, "tfixtureworker");
  const latest = task.workers.find((w) => w.terminal === "tfixtureworker");
  const point = findElement(root, `activity-point-${latest.event}`);
  assert.ok(point);
  point.click({}, host.cx);
  assert.match(textContent(view.inspector(task, host.cx)), /Synthetic worker report/);
});

test("expanded view survives remount and restores the exact layout width", () => {
  const snapshot = readFixture("revision"), host = viewHarness(snapshot), view = new host.Work();
  host.state.set(`work.source.${snapshot.registration.space}`, { snapshot, path: "/fixture/snapshot.json", readAt: Date.now(), error: null, notice: null });
  host.panel(480); // The panel width is authoritative before the new view is measured.
  let root = view.render(host.cx);
  assert.equal(findElement(root, "work-expand").label, "Expand Work");
  findElement(root, "work-expand").click({}, host.cx);
  assert.equal(host.commands.at(-1).args.id, "panel");
  assert.equal(host.commands.at(-1).args.px, 720);
  const remounted = new host.Work();
  root = remounted.render(host.cx);
  assert.equal(findElement(root, "work-expand").label, "Restore Work width");
  findElement(root, "work-expand").click({}, host.cx);
  assert.equal(host.commands.at(-1).args.id, "panel");
  assert.equal(host.commands.at(-1).args.px, 480);
  assert.equal(new host.Work().expansion().kind, "compact");
});

test("manually wide panel offers collapse without inventing a prior width", () => {
  const snapshot = readFixture("revision"), host = viewHarness(snapshot), view = new host.Work();
  host.state.set(`work.source.${snapshot.registration.space}`, { snapshot, path: "/fixture/snapshot.json", readAt: host.clock(), error: null, notice: null });
  host.panel(880);
  const root = view.render(host.cx);
  assert.equal(findElement(root, "work-expand").label, "Collapse Work");
  findElement(root, "work-expand").click({}, host.cx);
  assert.equal(host.commands.at(-1).args.px, 480);
});

test("one old report leaves an unknown gap through now and timer refresh survives a throttled read", async () => {
  const snapshot = readFixture("revision"), task = snapshot.tasks[0], host = viewHarness(snapshot), view = new host.Work();
  const report = { ...task.activity[0], at: new Date(host.clock() - 24 * 60000).toISOString() };
  task.activity = [report]; task.workers = [report];
  const geometry = activityGeometry(task, 448, host.clock());
  assert.equal(geometry.end - geometry.start, 24 * 60000);
  assert.equal(geometry.reports.length, 1);
  assert.equal(geometry.x(report.at), 16);
  assert.equal(geometry.x(new Date(host.clock()).toISOString()), 432);
  const before = textContent(view.activityStrip(task, report.terminal));
  assert.match(before, new RegExp(`Now ${time(new Date(host.clock()).toISOString())}`));
  const unchanged = JSON.stringify(snapshot.tasks);
  host.advance(60000);
  const key = `work.source.${snapshot.registration.space}`;
  host.state.set(key, { snapshot, path: "/fixture/snapshot.json", readAt: host.clock(), error: null, notice: null });
  const notifications = host.notifications();
  view.tick(host.cx); await host.drain();
  assert.equal(host.notifications(), notifications + 1);
  assert.equal(host.executions.length, 0);
  assert.notEqual(textContent(view.activityStrip(task, report.terminal)), before);
  assert.equal(JSON.stringify(host.state.get(key).snapshot.tasks), unchanged);
});

test("single task folds into summary while multiple-task selection remains accessible", () => {
  const snapshot = readFixture("revision"), host = viewHarness(snapshot), view = new host.Work();
  const key = `work.source.${snapshot.registration.space}`;
  host.state.set(key, { snapshot, path: "/fixture/snapshot.json", readAt: host.clock(), error: null, notice: null });
  let root = view.render(host.cx);
  assert.equal(findElement(root, "task-T001"), null);
  assert.match(textContent(root), /T001 · ISOLATED FIXTURE/);
  snapshot.tasks.push({ ...structuredClone(snapshot.tasks[0]), id: "T002", state: "queued", outcome: "Second task" });
  root = view.render(host.cx);
  assert.equal(findElement(root, "task-T002").label, "T002 · queued");
  findElement(root, "task-T002").click({}, host.cx);
  assert.equal(host.state.get(`work.task.${snapshot.registration.space}`), "T002");
  assert.match(textContent(view.render(host.cx)), /T002 · Second task/);
});

test("history uses integer ticks, a separate label gutter and a shelf beyond the final revision", () => {
  const task = readFixture("revision").tasks[0];
  const frame = historyGeometry(task, 448);
  assert.deepEqual(frame.ticks.map((t) => t.value), [0, 1, 2, 3]);
  assert.equal(frame.left, 32);
  assert.equal(frame.width - frame.right, 16);
  assert.equal(frame.right - frame.x(task.history.at(-1).at), 16);
  assert.equal(frame.y(0), frame.bottom);
  const due = "2026-01-01T10:05:00Z";
  assert.equal(deadline(due, Date.parse("2026-01-01T10:02:00Z")), "Due in 3m");
  assert.equal(deadline(due, Date.parse("2026-01-01T10:08:00Z")), "3m overdue");
  assert.match(time(due), /^\d{2}:\d{2}$/);
});
