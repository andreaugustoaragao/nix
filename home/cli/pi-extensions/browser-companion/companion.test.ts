import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { display, parseTask, runBrowserTask, validateUrl } from "./cli.ts";
import type { Runner, Task } from "./cli.ts";
import { registerCompanion } from "./index.ts";

test("CLI transport bounds output, reports failures, cancels, and never interpolates a shell", async () => {
  const directory = await mkdtemp(join(tmpdir(), "pi-browser-companion-test-"));
  const previousPath = process.env.PATH;
  try {
    await writeFile(join(directory, "browser-task"), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const input = fs.readFileSync(0, 'utf8');
if (args[0] === 'fail') { process.stderr.write('profile unavailable'); process.exit(2); }
else if (args[0] === 'invalid') process.stdout.write('not JSON');
else if (args[0] === 'large') process.stdout.write('x'.repeat(2 * 1024 * 1024));
else if (args[0] === 'stall') setTimeout(() => process.exit(), 60000);
else process.stdout.write(JSON.stringify({ args, input }));
`, { mode: 0o700 });
    process.env.PATH = directory;
    const args = ["echo", "; touch /tmp/never-run-this", "$(false)"];
    assert.deepEqual(await runBrowserTask(args, { type: "screenshot" }), {
      args, input: '{"type":"screenshot"}',
    });
    await assert.rejects(runBrowserTask(["fail"]), /profile unavailable/);
    await assert.rejects(runBrowserTask(["invalid"]), /invalid JSON/);
    await assert.rejects(runBrowserTask(["large"]), /exceeded 1 MiB/);
    const controller = new AbortController();
    const pending = runBrowserTask(["stall"], undefined, controller.signal);
    const timer = setTimeout(() => controller.abort(), 50);
    try { await assert.rejects(pending, /cancelled/); } finally { clearTimeout(timer); }
    await assert.rejects(runBrowserTask(["echo"], undefined, controller.signal), /cancelled/);
    process.env.PATH = join(directory, "missing");
    await assert.rejects(runBrowserTask(["info"]), /Cannot run browser-task/);
  } finally {
    if (previousPath === undefined) delete process.env.PATH;
    else process.env.PATH = previousPath;
    await rm(directory, { recursive: true, force: true });
  }
});

const ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const OTHER = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
const STATE = "browser-companion.selection.v1";
const taskRecord = (id = ID, state: Task["state"] = "active"): Task => ({
  task: id, label: "Same task label", profile: "development", state,
  pages: { main: "target-main", mobile: "target-mobile" },
});

type Hook = (event: never, ctx: ExtensionContext) => unknown;
type Handler = (args: string, ctx: ExtensionCommandContext) => Promise<void>;

function harness() {
  const hooks = new Map<string, Hook>();
  let handler: Handler;
  const calls: { args: string[]; input?: unknown }[] = [];
  const entries: { type: string; customType: string; data: unknown }[] = [];
  const notices: { message: string; type?: string }[] = [];
  const widgets: (string[] | undefined)[] = [];
  const choices: (string | undefined)[] = [];
  const inputs: (string | undefined)[] = [];
  const confirmations: boolean[] = [];
  const tasks = new Map([[ID, taskRecord()], [OTHER, taskRecord(OTHER, "kept")]]);
  let failCapture = false;
  let failInfo = false;
  const run: Runner = async (args, input) => {
    calls.push({ args, input });
    const [command, id] = args;
    if (command === "list") return [...tasks.values(), { task: "invalid", error: "locked" }];
    if (command === "start") {
      const created = taskRecord("cccccccc-cccc-cccc-cccc-cccccccccccc");
      created.profile = id as Task["profile"];
      created.label = args[args.indexOf("--label") + 1];
      tasks.set(created.task, created);
      return structuredClone(created);
    }
    const current = tasks.get(id);
    if (command === "info" && failInfo) throw new Error("Task was cleaned up.");
    if (!current) throw new Error("Unknown task.");
    if (command === "info") return structuredClone(current);
    if (command === "action") {
      if (failCapture) { current.state = "kept"; throw new Error("Screenshot timed out."); }
      assert.deepEqual(input, { type: "screenshot" });
      return { path: "/tmp/private-capture.png", mime: "image/png", bytes: 42 };
    }
    if (command === "open") {
      current.pages[args[args.indexOf("--page") + 1]] = "target-new";
    } else if (command === "keep") current.state = "kept";
    else if (command === "resume") current.state = "active";
    else if (command === "finish") current.state = "finished";
    else throw new Error(`Unexpected command ${command}`);
    return structuredClone(current);
  };
  const pi = {
    on: (name: string, hook: Hook) => { hooks.set(name, hook); return () => hooks.delete(name); },
    appendEntry: (customType: string, data: unknown) => entries.push({ type: "custom", customType, data: structuredClone(data) }),
    registerCommand: (name: string, options: { handler: Handler }) => { assert.equal(name, "browser"); handler = options.handler; },
  } as unknown as ExtensionAPI;
  const ctx = {
    mode: "rpc", hasUI: true, isIdle: () => true,
    sessionManager: { getBranch: () => entries },
    ui: {
      select: async (_title: string, options: string[]) => {
        const choice = choices.shift();
        return choice === "FIRST_TASK" ? options[1] : choice;
      },
      input: async () => inputs.shift(),
      confirm: async () => confirmations.shift() ?? false,
      notify: (message: string, type?: string) => notices.push({ message, type }),
      setWidget: (_key: string, lines: string[] | undefined) => widgets.push(lines),
      setStatus: () => {},
    },
  } as unknown as ExtensionCommandContext;
  registerCompanion(pi, run);
  return {
    calls, entries, notices, widgets, choices, inputs, confirmations, tasks, ctx,
    command: (args: string) => handler(args, ctx),
    emit: async (name: string, event: unknown = {}) => hooks.get(name)?.(event as never, ctx),
    failCapture: () => { failCapture = true; },
    failInfo: () => { failInfo = true; },
    lines: () => widgets.at(-1)?.join("\n") ?? "",
  };
}

test("validate managed records and reject identity mismatches", () => {
  assert.equal(parseTask(taskRecord()).task, ID);
  assert.throws(() => parseTask(taskRecord(), OTHER));
  assert.throws(() => parseTask({ ...taskRecord(), profile: "everyday" }));
  assert.throws(() => parseTask({ ...taskRecord(), pages: { "--config": "target" } }));
  assert.throws(() => parseTask({ ...taskRecord(), state: "unknown" }));
});

test("terminal text and URLs cannot inject controls, flags, credentials, or executable schemes", () => {
  assert.equal(display("\x1b[31mhello\nworld\u202e"), "hello world ");
  assert.equal(validateUrl(""), "about:blank");
  assert.equal(validateUrl("http://localhost:3000"), "http://localhost:3000");
  for (const url of ["javascript:alert(1)", "file:///etc/passwd", "https://user:pass@example.com", "--config"]) {
    assert.throws(() => validateUrl(url));
  }
});

test("startup with no selection never queries, adopts, or mutates existing tasks", async () => {
  const h = harness();
  await h.emit("session_start");
  assert.deepEqual(h.calls, []);
  assert.equal(h.lines(), "");
});

test("creation is explicit, uses chosen profile, and retains returned UUID", async () => {
  const h = harness();
  h.choices.push("development — local apps and tests");
  h.inputs.push("Companion test", "");
  await h.command("start");
  assert.deepEqual(h.calls.map(call => call.args), [
    ["start", "development", "--label", "Companion test", "--url", "about:blank"],
  ]);
  assert.match(h.lines(), /cccccccc-cccc-cccc-cccc-cccccccccccc/);
  assert.equal(h.tasks.get(OTHER)?.state, "kept");
});

test("cancelled or invalid creation never starts a task", async () => {
  const h = harness();
  await h.command("start");
  h.choices.push("development — local apps and tests");
  h.inputs.push("--config");
  await h.command("start");
  h.choices.push("development — local apps and tests");
  h.inputs.push("A label", "https://user:pass@example.com");
  await h.command("start");
  assert.deepEqual(h.calls, []);
});

test("picker is read-only until explicit selection; duplicate labels have full UUIDs", async () => {
  const h = harness();
  await h.command("pick");
  assert.deepEqual(h.calls.map(call => call.args[0]), ["list"]);
  assert.equal(h.lines(), "");
  h.choices.push("FIRST_TASK");
  await h.command("pick");
  assert.match(h.lines(), new RegExp(ID));
  assert.equal(h.tasks.get(OTHER)?.state, "kept");
  assert.ok(h.notices.some(notice => notice.type === "warning"));
});

test("explicit UUID selection persists task/page without adding model messages", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  assert.deepEqual(h.entries.at(-1)?.data, { task: ID, page: "main" });
  assert.match(h.lines(), /development · active/);
  assert.deepEqual(h.calls.map(call => call.args), [["info", ID]]);
});

test("invalid selection does not invoke CLI and no-UI invocation fails closed", async () => {
  const h = harness();
  await h.command("use --config");
  assert.deepEqual(h.calls, []);
  (h.ctx as unknown as { hasUI: boolean }).hasUI = false;
  await assert.rejects(h.command("start"), /requires interactive/);
  assert.deepEqual(h.calls, []);
});

test("lifecycle controls refuse to race an active agent", async () => {
  const h = harness();
  (h.ctx as unknown as { isIdle: () => boolean }).isIdle = () => false;
  await h.command(`use ${ID}`);
  assert.deepEqual(h.calls, []);
  assert.match(h.notices.at(-1)?.message ?? "", /settle/);
});

test("keep confirms, captures private PNG first, and changes only selected task", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  h.confirmations.push(true);
  await h.command("keep");
  assert.deepEqual(h.calls.filter(call => call.args[0] !== "info").map(call => call.args[0]), ["action", "keep"]);
  assert.equal(h.tasks.get(ID)?.state, "kept");
  assert.equal(h.tasks.get(OTHER)?.state, "kept");
  assert.match(h.lines(), /Last capture \(main\): \/tmp\/private-capture.png/);
  assert.match(h.lines(), /development · kept/);
});

test("failed screenshot never executes keep; widget reflects service protection", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  h.failCapture(); h.confirmations.push(true);
  await h.command("keep");
  assert.equal(h.calls.filter(call => call.args[0] === "action").length, 1);
  assert.ok(!h.calls.some(call => call.args[0] === "keep"));
  assert.match(h.lines(), /development · kept/);
  assert.match(h.lines(), /Screenshot timed out/);
  assert.doesNotMatch(h.lines(), /Last capture/);
});

test("kept task refuses capture/finish; resume is explicit and confirmed", async () => {
  const h = harness();
  await h.command(`use ${OTHER}`);
  await h.command("screenshot"); await h.command("finish");
  assert.ok(h.calls.every(call => call.args[0] === "info"));
  await h.command("resume");
  assert.ok(!h.calls.some(call => call.args[0] === "resume"));
  h.confirmations.push(true);
  await h.command("resume");
  assert.equal(h.tasks.get(OTHER)?.state, "active");
});

test("refresh detects externally kept state; finish cancellation leaves it alone", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  await h.command("finish");
  assert.equal(h.tasks.get(ID)?.state, "active");
  h.tasks.get(ID)!.state = "kept";
  h.confirmations.push(true);
  await h.command("finish");
  assert.ok(!h.calls.some(call => call.args[0] === "finish"));
});

test("confirmed finish affects only explicitly selected active task", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  h.confirmations.push(true);
  await h.command("finish");
  assert.equal(h.tasks.get(ID)?.state, "finished");
  assert.equal(h.tasks.get(OTHER)?.state, "kept");
});

test("page selection and new page use owned CLI; duplicate names are refused", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  h.choices.push("mobile");
  await h.command("page");
  assert.match(h.lines(), /page mobile/);
  h.inputs.push("main");
  await h.command("open");
  assert.ok(!h.calls.some(call => call.args[0] === "open"));
  h.inputs.push("details", "http://localhost:3000");
  await h.command("open");
  assert.deepEqual(h.calls.find(call => call.args[0] === "open")?.args,
    ["open", ID, "--page", "details", "--url", "http://localhost:3000"]);
  assert.match(h.lines(), /page details/);
});

test("forget and shutdown never change browser lifecycle", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  await h.command("forget");
  assert.equal(h.entries.at(-1)?.data, null);
  await h.emit("session_shutdown");
  assert.deepEqual(h.calls.map(call => call.args[0]), ["info"]);
  assert.equal(h.lines(), "");
});

test("branch restore uses only supplied branch state and does not resume", async () => {
  const h = harness();
  h.entries.push({ type: "custom", customType: STATE, data: { task: OTHER, page: "mobile" } });
  await h.emit("session_start");
  assert.match(h.lines(), /development · kept/);
  assert.match(h.lines(), /page mobile/);
  h.entries.push({ type: "custom", customType: STATE, data: null });
  await h.emit("session_tree");
  assert.equal(h.lines(), "");
  assert.deepEqual(h.calls.map(call => call.args), [["info", OTHER]]);
});

test("removed task stays visible as unknown; no automatic recreation or resume", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  h.failInfo();
  await h.emit("agent_settled");
  assert.match(h.lines(), new RegExp(ID));
  assert.match(h.lines(), /unknown state/);
  assert.match(h.lines(), /cleaned up/);
  assert.ok(h.calls.every(call => call.args[0] === "info"));
});

test("native browser screenshot observation only records the selected task", async () => {
  const h = harness();
  await h.command(`use ${ID}`);
  const event = (id: string, isError = false) => ({
    toolName: "dev_browser", isError, input: { task: id, page: "mobile", action: { type: "screenshot" } },
    details: {}, content: [{ type: "text", text: JSON.stringify({ path: "/tmp/observed.png", mime: "image/png" }) }],
  });
  await h.emit("tool_result", event(OTHER));
  await h.emit("tool_result", event(ID, true));
  assert.doesNotMatch(h.lines(), /Last capture/);
  await h.emit("tool_result", event(ID));
  assert.match(h.lines(), /Last capture \(mobile\): \/tmp\/observed.png/);
});
