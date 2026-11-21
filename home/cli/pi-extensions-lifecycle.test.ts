import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs/promises";
import { readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { registerHooks, syncBuiltinESMExports } from "node:module";
import { spawnSync } from "node:child_process";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionFactory, ExtensionToolContext } from "@earendil-works/pi-coding-agent";

const modules = process.env.PI_EXTENSION_NODE_MODULES;
if (!modules) throw new Error("PI_EXTENSION_NODE_MODULES must identify the pinned Pi node_modules");
const hookOptions: Parameters<typeof registerHooks>[0] = { resolve(specifier, context, next) {
  try { return next(specifier, context); }
  catch (error) {
    if (specifier.startsWith(".") || specifier.startsWith("/") || specifier.includes(":")) throw error;
    if (specifier.includes("/dist/")) return next(pathToFileURL(join(modules, specifier)).href, context);
    return next(specifier, { ...context, parentURL: pathToFileURL(join(modules, "..", "package.json")).href });
  }
} };
const moduleHooks = registerHooks(hookOptions);
const lifecycle = await import("./pi-extensions/lib/lifecycle.ts");
const lsp = await import("./lsp-extension.ts");
const { loadExtensionFromFactory, createExtensionRuntime } = await import("@earendil-works/pi-coding-agent/dist/core/extensions/loader.js");
const { createEventBus } = await import("@earendil-works/pi-coding-agent/dist/core/event-bus.js");
const { ExtensionRunner } = await import("@earendil-works/pi-coding-agent/dist/core/extensions/runner.js");
const { wrapRegisteredTools } = await import("@earendil-works/pi-coding-agent/dist/core/extensions/wrapper.js");
const { SessionManager } = await import("@earendil-works/pi-coding-agent/dist/core/session-manager.js");
const { ModelRegistry } = await import("@earendil-works/pi-coding-agent/dist/core/model-registry.js");
const { ModelRuntime } = await import("@earendil-works/pi-coding-agent/dist/core/model-runtime.js");
const { runToolCall } = await import("@earendil-works/pi-agent-core/dist/agent-loop.js");
const { executeCodemode } = await import("@earendil-works/pi-coding-agent/dist/extensions/codemode/execute.js");
moduleHooks.deregister();
async function fixtureImport(url: string) {
  const hooks = registerHooks(hookOptions);
  try { return await import(url); } finally { hooks.deregister(); }
}
const pythonResult = spawnSync("python3", ["-c", "import sys; print(sys.executable)"], { encoding: "utf8" });
assert.equal(pythonResult.status, 0, pythonResult.stderr);
const fixturePython = pythonResult.stdout.trim();
const sourceRoot = dirname(new URL(import.meta.url).pathname);
const sleep = (ms: number) => new Promise<void>(done => setTimeout(done, ms));
async function waitFor(predicate: () => boolean, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) { if (Date.now() >= deadline) throw new Error("Fixture observation timed out"); await sleep(5); }
}
async function fixture() {
  const dir = await fs.mkdtemp(join(tmpdir(), "t029-lifecycle-fixture-"));
  const previousEvents = process.env.PI_LIFECYCLE_EVENTS_FILE;
  const previousState = process.env.XDG_STATE_HOME;
  process.env.PI_LIFECYCLE_EVENTS_FILE = join(dir, "events.jsonl");
  process.env.XDG_STATE_HOME = join(dir, "state");
  return { dir, events: join(dir, "events.jsonl"), async close() {
    if (previousEvents === undefined) delete process.env.PI_LIFECYCLE_EVENTS_FILE; else process.env.PI_LIFECYCLE_EVENTS_FILE = previousEvents;
    if (previousState === undefined) delete process.env.XDG_STATE_HOME; else process.env.XDG_STATE_HOME = previousState;
    await fs.rm(dir, { recursive: true, force: true });
  } };
}
function records(path: string): Record<string, unknown>[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8").split("\n").filter(Boolean).map(line => {
    const value: unknown = JSON.parse(line); assert.ok(lifecycle.isRecord(value)); return value;
  });
}
async function fakeLsp(dir: string, initFailure = false, holdAfterEof = false) {
  const path = join(dir, "fake-lsp");
  await fs.writeFile(path, `#!${fixturePython}
import json, os, signal, sys, threading, time
root = ${JSON.stringify(dir)}
open(root + '/spawn-' + str(os.getpid()), 'w').close()
${initFailure ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : ""}
commands = {}
lock = threading.Lock()
def send(frame):
    body = json.dumps(frame).encode()
    with lock:
        sys.stdout.buffer.write(('Content-Length: ' + str(len(body)) + '\\r\\n\\r\\n').encode() + body)
        sys.stdout.buffer.flush()
def handle(msg):
    if msg.get('method') == 'initialize':
        send({'id': msg['id'], ${initFailure ? "'error': {'code': -1, 'message': 'fixture init failed'}" : "'result': {'capabilities': {'renameProvider': True}}"}})
    if msg.get('method') == 'workspace/executeCommand':
        command, uri = msg['params']['command'], msg['params']['arguments'][0]
        open(root + '/dispatched-' + command, 'w').close()
        edit = {'changes': {uri: [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'newText': command}]}}
        if command == 'A':
            def late_apply():
                open(root + '/late-sent-A', 'w').close()
                send({'id': 900, 'method': 'workspace/applyEdit', 'params': {'edit': edit}})
            threading.Timer(.06, late_apply).start()
        elif command == 'queue-A':
            edit['changes'][uri][0]['newText'] = 'A'
            def held_a():
                while not os.path.exists(root + '/send-A-edit'): time.sleep(.005)
                send({'id': 902, 'method': 'workspace/applyEdit', 'params': {'edit': edit}})
                while not os.path.exists(root + '/release-A'): time.sleep(.005)
                send({'id': msg['id'], 'result': None})
            threading.Thread(target=held_a).start()
        else:
            commands[901] = msg['id']
            send({'id': 901, 'method': 'workspace/applyEdit', 'params': {'edit': edit}})
    if msg.get('id') == 902:
        with open(root + '/queue-a-ack', 'w') as out: json.dump(msg, out)
    if msg.get('method') == 'textDocument/didOpen':
        open(root + '/didopen-seen', 'w').close()
    if msg.get('method') == 'workspace/symbol':
        open(root + '/symbols-seen', 'w').close()
        if msg['params']['query'] == 'unsupported':
            send({'id': msg['id'], 'error': {'code': -32601, 'message': 'fixture unsupported workspace symbols'}})
    if msg.get('id') in commands:
        send({'id': commands.pop(msg['id']), 'result': None})
    if msg.get('method') == 'textDocument/rename':
        send({'id': msg['id'], 'result': {'changes': {msg['params']['textDocument']['uri']: [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'newText': 'B'}]}}})
while True:
    header = sys.stdin.buffer.readline()
    if not header: break
    size = int(header.split(b':')[1])
    assert sys.stdin.buffer.readline() == b'\\r\\n'
    body = sys.stdin.buffer.read(size)
    handle(json.loads(body))
${initFailure || holdAfterEof ? "while True: time.sleep(1)" : ""}
`, { mode: 0o700 });
  return { bin: path, args: [], languageId: "typescript", name: "fixture-lsp" };
}
async function runnerFor(factory: ExtensionFactory, dir: string) {
  const runtime = createExtensionRuntime();
  const extension = await loadExtensionFromFactory(factory, dir, createEventBus(), runtime, join(dir, "extension.ts"));
  const registry = new ModelRegistry(await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: null,
    modelsStorePath: join(dir, "models-store.json"), allowModelNetwork: false, refreshOnCreate: false }));
  const runner = new ExtensionRunner([extension], runtime, dir, SessionManager.inMemory(dir), registry);
  const tools = wrapRegisteredTools([...extension.tools.values()], runner);
  await runner.emit({ type: "session_start", reason: "startup" });
  return { runner, tools };
}

async function freshnessLsp(dir: string, silentAfterChange = false) {
  const binary = join(dir, "freshness-lsp");
  await fs.writeFile(binary, `#!${fixturePython}
import json, os, sys, threading, time
root = ${JSON.stringify(dir)}
with open(root + '/spawns.jsonl', 'a') as out: out.write(json.dumps({'pid': os.getpid()}) + '\\n')
successor = os.path.exists(root + '/mutated')
docs = {}
lock = threading.Lock()
def send(frame):
    body = json.dumps(frame).encode()
    with lock:
        sys.stdout.buffer.write(('Content-Length: ' + str(len(body)) + '\\r\\n\\r\\n').encode() + body)
        sys.stdout.buffer.flush()
def publish(uri, doc, versioned=False):
    diags = [{'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 5}}, 'message': "Cannot find name 'reslt'.", 'severity': 1, 'code': 2552}] if 'reslt' in doc['text'] else []
    params = {'uri': uri, 'diagnostics': diags}
    if versioned: params['version'] = doc['version']
    send({'method': 'textDocument/publishDiagnostics', 'params': params})
    with open(root + '/publications.jsonl', 'a') as out: out.write(json.dumps({'pid': os.getpid(), **params}) + '\\n')
def edit(uri, start, end, text, line=1):
    return {'changes': {uri: [{'range': {'start': {'line': line, 'character': start}, 'end': {'line': line, 'character': end}}, 'newText': text}]}}
def handle(msg):
    method, params = msg.get('method'), msg.get('params', {})
    if method == 'initialize': send({'id': msg['id'], 'result': {'capabilities': {'renameProvider': True, 'codeActionProvider': True}}})
    if method in ('textDocument/didOpen', 'textDocument/didChange'):
        uri = params['textDocument']['uri']
        with open(root + '/sync.jsonl', 'a') as out: out.write(json.dumps(msg) + '\\n')
        if method == 'textDocument/didOpen':
            if uri in docs: return
            docs[uri] = params['textDocument']
            ${silentAfterChange ? "if not successor: publish(uri, docs[uri])" : "publish(uri, docs[uri])"}
        else:
            previous = docs[uri]
            assert params['textDocument']['version'] > previous['version']
            docs[uri] = {**previous, 'version': params['textDocument']['version'], 'text': params['contentChanges'][0]['text']}
            publish(uri, previous, versioned=True)
            publish(uri, previous, versioned=False)
            ${silentAfterChange ? "pass" : "threading.Timer(.03, lambda uri=uri, doc=dict(docs[uri]): publish(uri, doc)).start()"}
    if method == 'textDocument/didClose':
        uri = params['textDocument']['uri']; previous = docs.pop(uri, None)
        if previous: publish(uri, previous)
        with open(root + '/sync.jsonl', 'a') as out: out.write(json.dumps(msg) + '\\n')
    if method == 'textDocument/codeAction':
        uri = params['textDocument']['uri']
        send({'id': msg['id'], 'result': [{'title': "Change spelling to 'result'", 'kind': 'quickfix', 'edit': edit(uri, 0, 5, 'result'), 'command': {'title': 'confirm', 'command': '_typescript.applyCodeActionCommand', 'arguments': []}}]})
    if method == 'workspace/executeCommand':
        open(root + '/mutated', 'w').close()
        for uri, doc in docs.items(): publish(uri, doc)
        open(root + '/stale-published', 'w').close()
        if os.path.exists(root + '/hold-command'):
            open(root + '/command-held', 'w').close()
            while not os.path.exists(root + '/release-command'): time.sleep(.005)
        send({'id': msg['id'], 'result': None})
    if method == 'textDocument/rename':
        open(root + '/mutated', 'w').close()
        uri = params['textDocument']['uri']
        width = len(docs[uri]['text'].splitlines()[1].rstrip(';'))
        send({'id': msg['id'], 'result': edit(uri, 0, width, params['newName'])})
    if method == 'workspace/willRenameFiles':
        open(root + '/mutated', 'w').close()
        uri = 'file://' + root + '/consumer.ts'
        send({'id': msg['id'], 'result': edit(uri, 0, 5, 'result')})
while True:
    header = sys.stdin.buffer.readline()
    if not header: break
    size = int(header.split(b':')[1]); assert sys.stdin.buffer.readline() == b'\\r\\n'
    handle(json.loads(sys.stdin.buffer.read(size)))
`, { mode: 0o700 });
  const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8");
  await enableCompletedTsPeer(binary, silentAfterChange);
  const modulePath = join(dir, "freshness.ts");
  await fs.writeFile(modulePath, raw.replace("___TS_LSP___", binary).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts"))));
  return { ...await runnerFor((await fixtureImport(pathToFileURL(modulePath).href)).default, dir),
    spec: { bin: binary, args: [], languageId: "typescript", name: "fixture-freshness" } };
}

// Older peers expose one full model via their publication helper. Adapt that
// model to the pinned completed protocol; the R12 peer below models partial
// publications and completed semantics independently.
async function enableCompletedTsPeer(binary: string, unavailableIsError = false) {
  const script = await fs.readFile(binary, "utf8");
  if (script.includes("_completed_ts_fixture")) return;
  const marker = "\nwhile True:\n    header = sys.stdin.buffer.readline()";
  assert.ok(script.includes(marker));
  const adapter = `
import threading
_completed_ts_fixture = True
_original_send, _original_loads = send, json.loads
_init_ids, _ts_docs, _ts_models, _ts_ready = set(), {}, {}, {}
def send(frame):
    if frame.get('id') in _init_ids and isinstance(frame.get('result'), dict):
        caps = frame['result'].setdefault('capabilities', {})
        caps['executeCommandProvider'] = {'commands': ['typescript.tsserverRequest']}
    if frame.get('method') == 'textDocument/publishDiagnostics':
        params = frame['params']; uri = params['uri']; doc = _ts_docs.get(uri)
        if doc and (params.get('version') == doc['version'] or ('version' not in params and not doc.get('changed'))):
            _ts_models[uri] = params['diagnostics']; _ts_ready.setdefault(uri, threading.Event()).set()
    return _original_send(frame)
def _completed_diagnostics(msg):
    command, args = msg['params']['arguments'][:2]; uri = 'file://' + args['file']
    if command == 'semanticDiagnosticsSync':
        if ${unavailableIsError ? "True" : "False"} and uri not in _ts_models:
            send({'id': msg['id'], 'result': {'type': 'response', 'command': command, 'success': False, 'message': 'TypeScript diagnostics unconfirmed for current document'}}); return
        _ts_ready.setdefault(uri, threading.Event()).wait()
    categories = {1: 'error', 2: 'warning', 3: 'message', 4: 'suggestion'}
    body = []
    for diagnostic in _ts_models.get(uri, []) if command == 'semanticDiagnosticsSync' else []:
        range = diagnostic['range']
        body.append({'start': {'line': range['start']['line'] + 1, 'offset': range['start']['character'] + 1},
                     'end': {'line': range['end']['line'] + 1, 'offset': range['end']['character'] + 1},
                     'text': diagnostic['message'], 'code': diagnostic.get('code', 0), 'category': categories.get(diagnostic.get('severity', 1), 'error')})
    send({'id': msg['id'], 'result': {'type': 'response', 'command': command, 'success': True, 'body': body}})
def _incoming(data, *args, **kwargs):
    msg = _original_loads(data, *args, **kwargs)
    if not isinstance(msg, dict): return msg
    method, params = msg.get('method'), msg.get('params', {})
    if method == 'initialize': _init_ids.add(msg['id'])
    if method in ('textDocument/didOpen', 'textDocument/didChange'):
        doc = params['textDocument']; uri = doc['uri']
        _ts_docs[uri] = {**doc, 'changed': method == 'textDocument/didChange'}
        _ts_models.pop(uri, None); _ts_ready.setdefault(uri, threading.Event()).clear()
    if method == 'textDocument/didClose': _ts_docs.pop(params['textDocument']['uri'], None)
    if method == 'workspace/executeCommand' and params.get('command') == 'typescript.tsserverRequest':
        threading.Thread(target=_completed_diagnostics, args=(msg,), daemon=True).start(); return {}
    return msg
json.loads = _incoming
`;
  await fs.writeFile(binary, script.replace(marker, adapter + marker));
}

for (const action of ["code_actions", "rename", "rename_file"]) {
  test(`LIVE-1 ${action} preview preserves evidence and apply opens a fresh diagnostic lifetime`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      const initial = 'export const result = "amber";\nreslt;\n';
      await fs.writeFile(join(f.dir, "file.ts"), initial); await fs.writeFile(join(f.dir, "consumer.ts"), initial);
      const harness = await freshnessLsp(f.dir); runner = harness.runner;
      const inspected = action === "rename_file" ? "consumer.ts" : "file.ts";
      const before = await toolCall("lsp", { action: "diagnostics", file: inspected }, harness.tools);
      assert.equal(before.isError, false); assert.match(JSON.stringify(before), /2552/);
      if (action === "rename_file") assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
      const args = { action, file: "file.ts", line: 2, query: "Change spelling", new_name: action === "rename_file" ? "renamed.ts" : "result" };
      const preview = await toolCall("lsp", { ...args, apply: false }, harness.tools); assert.equal(preview.isError, false);
      assert.equal(await fs.readFile(join(f.dir, inspected), "utf8"), initial);
      const spawnsBefore = records(join(f.dir, "spawns.jsonl")).length;
      const unchanged = await toolCall("lsp", { action: "diagnostics", file: inspected }, harness.tools);
      assert.equal(unchanged.isError, false); assert.match(JSON.stringify(unchanged), /2552/);
      assert.equal(records(join(f.dir, "spawns.jsonl")).length, spawnsBefore);
      const applied = await toolCall("lsp", { ...args, apply: true }, harness.tools); assert.equal(applied.isError, false);
      assert.equal(await fs.readFile(join(f.dir, inspected), "utf8"), initial.replace("reslt", "result"));
      const after = await toolCall("lsp", { action: "diagnostics", file: inspected }, harness.tools);
      assert.equal(after.isError, false); assert.doesNotMatch(JSON.stringify(after), /2552|reslt/); assert.match(JSON.stringify(after), /file is clean/);
      assert.equal((await toolCall("lsp", { action: "rename", file: inspected, line: 2, new_name: "reslt" }, harness.tools)).isError, false);
      const changedAgain = await toolCall("lsp", { action: "diagnostics", file: inspected }, harness.tools);
      assert.equal(changedAgain.isError, false); assert.match(JSON.stringify(changedAgain), /2552/);
      if (action === "rename_file") {
        assert.equal((await toolCall("lsp", { action: "diagnostics", file: "renamed.ts" }, harness.tools)).isError, false);
        assert.equal((await toolCall("lsp", { action: "diagnostics", file: "*" }, harness.tools)).isError, false, "Moved source must not remain an unconfirmed open document");
        const oldUri = pathToFileURL(join(f.dir, "file.ts")).href;
        assert.ok(records(join(f.dir, "sync.jsonl")).some(record => record.method === "textDocument/didClose" && lifecycle.isRecord(record.params) && lifecycle.isRecord(record.params.textDocument) && record.params.textDocument.uri === oldUri));
      }
      const uri = pathToFileURL(join(f.dir, inspected)).href;
      const messages = records(join(f.dir, "sync.jsonl")).filter(record => lifecycle.isRecord(record.params) && lifecycle.isRecord(record.params.textDocument) && record.params.textDocument.uri === uri);
      assert.deepEqual(messages.map(record => record.method), ["textDocument/didOpen", "textDocument/didOpen", "textDocument/didOpen"]);
      assert.deepEqual(messages.map(record => lifecycle.isRecord(record.params) && lifecycle.isRecord(record.params.textDocument) ? record.params.textDocument.version : null), [1, 1, 1]);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

test("LIVE-1 missing post-edit diagnostics is an error for file and workspace, never clean evidence", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    await fs.writeFile(join(f.dir, "file.ts"), 'export const result = "amber";\nreslt;\n');
    const harness = await freshnessLsp(f.dir, true); runner = harness.runner;
    assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
    assert.equal((await toolCall("lsp", { action: "code_actions", file: "file.ts", line: 2, query: "Change spelling", apply: true }, harness.tools)).isError, false);
    assert.equal(existsSync(join(f.dir, "stale-published")), true);
    const missing = await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools);
    assert.equal(missing.isError, true); assert.doesNotMatch(JSON.stringify(missing), /file is clean|2552/); assert.match(JSON.stringify(missing), /unconfirmed|not confirmed/i);
    const workspace = await toolCall("lsp", { action: "diagnostics", file: "*" }, harness.tools);
    assert.equal(workspace.isError, true); assert.match(JSON.stringify(workspace), /unconfirmed/i);
    const executeTool: ExtensionToolContext["executeTool"] = (name, args, options) => {
      assert.ok(isJsonObject(args)); return toolCall(name, args, harness.tools, options?.signal);
    };
    const ctx: ExtensionToolContext = Object.assign(runner.createContext(), { tools: harness.tools, executeTool });
    const code = await executeCodemode("f1-missing", { code: 'await tools.lsp({action:"diagnostics",file:"file.ts"});' }, undefined, undefined, ctx);
    assert.equal(code.isError, true); assert.match(JSON.stringify(code), /unconfirmed/i);
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});
test("F1 external changed disk uses a fresh lifetime through native and codemode diagnostics", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const file = join(f.dir, "file.ts"), initial = 'export const result = "amber";\nreslt;\n';
    await fs.writeFile(file, initial);
    const harness = await freshnessLsp(f.dir); runner = harness.runner;
    assert.match(JSON.stringify(await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)), /2552/);
    await fs.writeFile(file, initial.replace("reslt", "result"));
    const after = await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools);
    assert.equal(after.isError, false); assert.doesNotMatch(JSON.stringify(after), /2552|reslt/);
    assert.equal(records(join(f.dir, "spawns.jsonl")).length, 2);
    const executeTool: ExtensionToolContext["executeTool"] = (name, args, options) => {
      assert.ok(isJsonObject(args)); return toolCall(name, args, harness.tools, options?.signal);
    };
    const ctx: ExtensionToolContext = Object.assign(runner.createContext(), { tools: harness.tools, executeTool });
    const code = await executeCodemode("f1-fresh", { code: 'return await tools.lsp({action:"diagnostics",file:"file.ts"});' }, undefined, undefined, ctx);
    assert.notEqual(code.isError, true); assert.match(JSON.stringify(code), /file is clean/); assert.doesNotMatch(JSON.stringify(code), /2552|reslt/);
    assert.equal(records(join(f.dir, "spawns.jsonl")).length, 2, "Unchanged codemode query must reuse confirmed evidence");
    await fs.writeFile(file, initial);
    const workspace = await toolCall("lsp", { action: "diagnostics", file: "*" }, harness.tools);
    assert.ok(workspace.isError || /2552/.test(JSON.stringify(workspace)), "Workspace cannot return old clean evidence after external write");
    const dirty = await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools);
    assert.equal(dirty.isError, false); assert.match(JSON.stringify(dirty), /2552/);
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

test("F1 ensureOpen detects changed disk and rejects stale and current unversioned old-lifetime pushes", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const file = join(f.dir, "file.ts"), initial = 'export const result = "amber";\nreslt;\n';
    await fs.writeFile(file, initial);
    const harness = await freshnessLsp(f.dir); runner = harness.runner;
    const old = await pool.getClient(harness.spec, f.dir), uri = pathToFileURL(file).href;
    const first = old.waitForNextDiagnostics(uri, 1000); await old.ensureOpen(file, "typescript"); await first;
    assert.equal(old.hasDiagnosticsFor(uri), true);
    await fs.writeFile(file, initial.replace("reslt", "result"));
    const unconfirmed = assert.rejects(old.waitForNextDiagnostics(uri, 150), /unconfirmed/);
    await old.ensureOpen(file, "typescript"); await unconfirmed;
    assert.equal(old.hasDiagnosticsFor(uri), false); assert.deepEqual(old.getDiagnostics(uri), []);
    const publications = records(join(f.dir, "publications.jsonl"));
    assert.ok(publications.some(row => Array.isArray(row.diagnostics) && row.diagnostics.length > 0 && row.version === undefined));
    assert.ok(publications.some(row => Array.isArray(row.diagnostics) && row.diagnostics.length === 0 && row.version === undefined));
    assert.ok(publications.some(row => row.version === 1), "Explicit obsolete versions must remain rejected too");
    const fresh = await pool.getClient(harness.spec, f.dir); assert.notEqual(fresh, old);
    if (!fresh.hasDiagnosticsFor(uri)) await fresh.waitForNextDiagnostics(uri, 1000);
    assert.deepEqual(fresh.getDiagnostics(uri), []); assert.equal(fresh.hasDiagnosticsFor(uri), true);
    fresh.closeDocument(uri);
    await waitFor(() => records(join(f.dir, "sync.jsonl")).some(row => row.method === "textDocument/didClose"));
    assert.equal(fresh.hasDiagnosticsFor(uri), false); assert.deepEqual(fresh.getDiagnostics(uri), []);
  } finally { await pool.shutdown("quit", "fixture"); await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

test("F1 retirement waits for a held apply and its following authorized command before successor diagnostics", async () => {
  const f = await fixture(), original = fs.writeFile, calls: Promise<unknown>[] = [];
  let runner: InstanceType<typeof ExtensionRunner> | undefined, releaseApply = () => { };
  try {
    const file = join(f.dir, "file.ts"); await fs.writeFile(file, 'export const result = "amber";\nreslt;\n');
    const harness = await freshnessLsp(f.dir); runner = harness.runner;
    assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
    await fs.writeFile(join(f.dir, "hold-command"), "");
    let written = false;
    const gate = new Promise<void>(resolve => { releaseApply = resolve; });
    Object.defineProperty(fs, "writeFile", { value: async (...args: Parameters<typeof fs.writeFile>) => {
      const result = await original(...args);
      if (args[0] === file) { written = true; await gate; }
      return result;
    } }); syncBuiltinESMExports();
    const apply = toolCall("lsp", { action: "code_actions", file: "file.ts", line: 2, query: "Change spelling", apply: true }, harness.tools); calls.push(apply);
    await waitFor(() => written);
    let settled = false;
    const diagnostics = toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools).then(value => { settled = true; return value; }); calls.push(diagnostics);
    await sleep(40); assert.equal(settled, false); assert.equal(records(join(f.dir, "spawns.jsonl")).length, 1);
    releaseApply(); await waitFor(() => existsSync(join(f.dir, "command-held")));
    await sleep(40); assert.equal(settled, false); assert.equal(records(join(f.dir, "spawns.jsonl")).length, 1);
    const abort = new AbortController();
    const cancelled = toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools, abort.signal); calls.push(cancelled);
    const started = Date.now(); abort.abort();
    assert.equal((await cancelled).isError, true); assert.ok(Date.now() - started < 500);
    assert.equal(existsSync(join(f.dir, "stale-published")), true);
    await original(join(f.dir, "release-command"), "");
    assert.equal((await apply).isError, false);
    const fresh = await diagnostics; assert.equal(fresh.isError, false); assert.doesNotMatch(JSON.stringify(fresh), /2552|reslt/);
    assert.equal(records(join(f.dir, "spawns.jsonl")).length, 2);
    const executeTool: ExtensionToolContext["executeTool"] = (name, args, options) => {
      assert.ok(isJsonObject(args)); return toolCall(name, args, harness.tools, options?.signal);
    };
    const ctx: ExtensionToolContext = Object.assign(runner.createContext(), { tools: harness.tools, executeTool });
    assert.notEqual((await executeCodemode("f1-after-apply", { code: 'return await tools.lsp({action:"diagnostics",file:"file.ts"});' }, undefined, undefined, ctx)).isError, true);
  } finally {
    releaseApply(); await original(join(f.dir, "release-command"), "");
    Object.defineProperty(fs, "writeFile", { value: original }); syncBuiltinESMExports();
    await runner?.emit({ type: "session_shutdown", reason: "quit" }); await Promise.allSettled(calls); await f.close();
  }
});

test("F1 freshness retirement surfaces and retains an actual owned-group cleanup failure", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool(), original = process.kill;
  let ownedPid: number | undefined;
  try {
    const spec = await fakeLsp(f.dir, false, true), file = join(f.dir, "file.ts"); await fs.writeFile(file, "x");
    const client = await pool.getClient(spec, f.dir); await client.ensureOpen(file, "typescript");
    await waitFor(() => existsSync(join(f.dir, "didopen-seen")));
    const birth = records(f.events).find(row => row.kind === "group_birth"); assert.ok(birth && typeof birth.childPid === "number"); ownedPid = birth.childPid;
    Object.defineProperty(process, "kill", { value: (pid: number, signal?: Parameters<typeof process.kill>[1]) => {
      if (ownedPid !== undefined && pid === -ownedPid && signal !== 0) throw Object.assign(new Error("fixture denied freshness group signal"), { code: "EPERM" });
      return original(pid, signal);
    } });
    await fs.writeFile(file, "changed");
    await assert.rejects(pool.getClient(spec, f.dir), /freshness retirement failed.*denied freshness group signal/);
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1, "Failed cleanup cannot admit a successor");
    Object.defineProperty(process, "kill", { value: original });
    original(-ownedPid, "SIGKILL");
    await assert.rejects(pool.shutdown("quit", "fixture"), /session cleanup failed: 1 groups/);
    assert.equal(records(f.events).find(row => row.kind === "shutdown_summary")?.ok, false);
  } finally {
    Object.defineProperty(process, "kill", { value: original });
    if (ownedPid) { try { original(-ownedPid, "SIGKILL"); } catch {} }
    await pool.shutdown("quit", "fixture").catch(() => { }); await f.close();
  }
});

test("F1 an aborted acquiring caller cannot evict its initialized shared successor", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool();
  try {
    const spec = await fakeLsp(f.dir), file = join(f.dir, "file.ts"); await fs.writeFile(file, "x");
    let initialized: InstanceType<typeof lsp.LspClient> | undefined;
    const cancelled = (client: InstanceType<typeof lsp.LspClient>) => { initialized = client; throw new DOMException("Operation cancelled", "AbortError"); };
    await assert.rejects(pool.getClient(spec, f.dir, cancelled), { name: "AbortError" });
    const first = await pool.getClient(spec, f.dir); assert.equal(first, initialized);
    await first.ensureOpen(file, "typescript"); await fs.writeFile(file, "changed");
    await assert.rejects(pool.getClient(spec, f.dir, cancelled), { name: "AbortError" });
    const second = await pool.getClient(spec, f.dir); assert.notEqual(first, second); assert.equal(second, initialized);
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 2);
  } finally { await pool.shutdown("quit", "fixture"); await f.close(); }
});

async function concurrencyLsp(dir: string, holdDiagnostics = false) {
  const binary = join(dir, "concurrency-lsp");
  await fs.writeFile(binary, `#!${fixturePython}
import json, os, sys, threading, time
root = ${JSON.stringify(dir)}
lock = threading.Lock()
def send(frame):
    body = json.dumps(frame).encode()
    with lock:
        sys.stdout.buffer.write(('Content-Length: ' + str(len(body)) + '\\r\\n\\r\\n').encode() + body)
        sys.stdout.buffer.flush()
def publish(doc):
    ${holdDiagnostics ? "while not os.path.exists(root + '/release-publication'): time.sleep(.005)" : "pass"}
    send({'method': 'textDocument/publishDiagnostics', 'params': {'uri': doc['uri'], 'diagnostics': []}})
    with open(root + '/publications.jsonl', 'a') as out: out.write(json.dumps({'uri': doc['uri']}) + '\\n')
def held_symbols(msg):
    open(root + '/symbols-held', 'w').close()
    while not os.path.exists(root + '/release-symbols'): time.sleep(.005)
    send({'id': msg['id'], 'result': [{'name': 'result', 'kind': 13, 'location': {'uri': 'file://' + root + '/file.ts', 'range': {'start': {'line': 0, 'character': 6}, 'end': {'line': 0, 'character': 12}}}}]})
def handle(msg):
    method, params = msg.get('method'), msg.get('params', {})
    if method == 'initialize': send({'id': msg['id'], 'result': {'capabilities': {}}})
    if method == 'textDocument/didOpen': threading.Thread(target=publish, args=(params['textDocument'],)).start()
    if method == 'workspace/symbol':
        query = params['query']
        if query == 'held': threading.Thread(target=held_symbols, args=(msg,)).start()
        elif query == 'transport': sys.exit(7)
        elif query == 'rpc-error': send({'id': msg['id'], 'error': {'code': -32603, 'message': 'fixture ordinary symbol RPC failure'}})
        elif query == 'unsupported': send({'id': msg['id'], 'error': {'code': -32601, 'message': 'fixture method unsupported'}})
        else: send({'id': msg['id'], 'result': []})
while True:
    header = sys.stdin.buffer.readline()
    if not header: break
    size = int(header.split(b':')[1]); assert sys.stdin.buffer.readline() == b'\\r\\n'
    handle(json.loads(sys.stdin.buffer.read(size)))
`, { mode: 0o700 });
  const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8");
  await enableCompletedTsPeer(binary);
  const modulePath = join(dir, "concurrency.ts");
  await fs.writeFile(modulePath, raw.replace("___TS_LSP___", binary).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts"))));
  return runnerFor((await fixtureImport(pathToFileURL(modulePath).href)).default, dir);
}

test("R6 symbols retain their operation until a held request settles before changed-disk retirement", async () => {
  const f = await fixture(), calls: Promise<unknown>[] = []; let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const file = join(f.dir, "file.ts"); await fs.writeFile(file, "const result = 1;\n");
    const harness = await concurrencyLsp(f.dir); runner = harness.runner;
    assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
    const symbols = toolCall("lsp", { action: "symbols", file: "*", query: "held" }, harness.tools); calls.push(symbols);
    await waitFor(() => existsSync(join(f.dir, "symbols-held")));
    await fs.writeFile(file, "const changed = 2;\n");
    let settled = false;
    const diagnostics = toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools).then(value => { settled = true; return value; }); calls.push(diagnostics);
    await sleep(40); assert.equal(settled, false);
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1);
    assert.equal(records(f.events).filter(row => row.kind === "group_settled").length, 0);
    await fs.writeFile(join(f.dir, "release-symbols"), "");
    const result = await symbols; assert.equal(result.isError, false); assert.match(JSON.stringify(result), /1 symbol\(s\).*result/s);
    assert.equal((await diagnostics).isError, false);
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 2);
    assert.equal(records(f.events).find(row => row.kind === "group_settled")?.ok, true);
  } finally {
    await fs.writeFile(join(f.dir, "release-symbols"), "");
    await runner?.emit({ type: "session_shutdown", reason: "quit" }); await Promise.allSettled(calls); await f.close();
  }
});

test("R6 symbols preserve ordinary RPC and transport failures while empty and unsupported remain successful", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    await fs.writeFile(join(f.dir, "file.ts"), "const result = 1;\n");
    const harness = await concurrencyLsp(f.dir); runner = harness.runner;
    assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
    for (const query of ["empty", "unsupported"]) {
      const result = await toolCall("lsp", { action: "symbols", file: "*", query }, harness.tools);
      assert.equal(result.isError, false); assert.match(JSON.stringify(result), /No workspace symbols match/);
    }
    const rpc = await toolCall("lsp", { action: "symbols", file: "*", query: "rpc-error" }, harness.tools);
    assert.equal(rpc.isError, true); assert.match(JSON.stringify(rpc), /ordinary symbol RPC failure/);
    const transport = await toolCall("lsp", { action: "symbols", file: "*", query: "transport" }, harness.tools);
    assert.equal(transport.isError, true); assert.match(JSON.stringify(transport), /exited|failed/); assert.doesNotMatch(JSON.stringify(transport), /No workspace symbols match/);
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

for (const cancelSecond of [false, true, "shutdown"]) {
  test(`R6 same-URI diagnostic callers own independent waiters (second cancelled=${cancelSecond})`, async () => {
    const f = await fixture(), original = fs.readFile, calls: Promise<unknown>[] = [];
    let runner: InstanceType<typeof ExtensionRunner> | undefined, releaseReads = () => { };
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "const result = 1;\n");
      const harness = await concurrencyLsp(f.dir, true); runner = harness.runner;
      let reads = 0;
      const gate = new Promise<void>(resolve => { releaseReads = resolve; });
      Object.defineProperty(fs, "readFile", { value: async (...args: Parameters<typeof fs.readFile>) => {
        if (args[0] === file) { reads++; await gate; }
        return original(...args);
      } }); syncBuiltinESMExports();
      const first = toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools); calls.push(first);
      await waitFor(() => reads === 1);
      const abort = new AbortController();
      const second = toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools, abort.signal); calls.push(second);
      await waitFor(() => reads === 2); releaseReads();
      if (cancelSecond === "shutdown") {
        const start = Date.now(), shutdown = runner.emit({ type: "session_shutdown", reason: "quit" });
        const outcomes = await Promise.all([first, second]);
        assert.ok(Date.now() - start < 500, "Shutdown must settle both waiters promptly");
        for (const outcome of outcomes) { assert.equal(outcome.isError, true); assert.match(JSON.stringify(outcome), /cancel/i); }
        await shutdown; return;
      }
      if (cancelSecond) {
        const start = Date.now(); abort.abort(); const cancelled = await second;
        assert.equal(cancelled.isError, true); assert.match(JSON.stringify(cancelled), /cancel/i); assert.ok(Date.now() - start < 500);
      }
      await fs.writeFile(join(f.dir, "release-publication"), "");
      const result = await first; assert.equal(result.isError, false); assert.match(JSON.stringify(result), /file is clean/);
      if (!cancelSecond) assert.equal((await second).isError, false);
      assert.equal(records(join(f.dir, "publications.jsonl")).length, 1, "A single accepted publication must settle every live caller");
      assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
      assert.equal(records(join(f.dir, "publications.jsonl")).length, 1);
    } finally {
      releaseReads(); await fs.writeFile(join(f.dir, "release-publication"), "");
      Object.defineProperty(fs, "readFile", { value: original }); syncBuiltinESMExports();
      await runner?.emit({ type: "session_shutdown", reason: "quit" }); await Promise.allSettled(calls); await f.close();
    }
  });
}

for (const cancel of [false, true]) {
  test(`R7 failed plus deferred workspace preparation releases retained scope (cancelled=${cancel})`, async () => {
    const f = await fixture(), calls: Promise<unknown>[] = [], cleanupReleases = new Set<() => void>();
    let runner: InstanceType<typeof ExtensionRunner> | undefined, ownerPool: InstanceType<typeof lsp.LspSessionPool> | undefined;
    let extensionPool: InstanceType<typeof lsp.LspSessionPool> | undefined, client: InstanceType<typeof lsp.LspClient> | undefined;
    let resolveLate = (_client: InstanceType<typeof lsp.LspClient>) => { }, restoreContext = () => { }, started = false;
    let retained = 0, released = 0, retainArrived = () => { };
    const retainedArrival = new Promise<void>(resolve => { retainArrived = resolve; });
    try {
      const spec = await fakeLsp(f.dir), file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n");
      const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8"), modulePath = join(f.dir, "workspace-preparation.ts");
      await fs.writeFile(modulePath, raw.replace("___TS_LSP___", spec.bin).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts"))));
      await enableCompletedTsPeer(spec.bin);
      const loaded = await fixtureImport(pathToFileURL(modulePath).href);
      const LoadedPool: typeof lsp.LspSessionPool = loaded.LspSessionPool;
      ownerPool = new LoadedPool(); client = await ownerPool.getClient(spec, f.dir);
      await client.ensureOpen(file, "typescript");
      const originalRetain = client.retainOperation.bind(client);
      client.retainOperation = () => {
        retained++; const release = originalRetain();
        const finish = () => { if (!cleanupReleases.delete(finish)) return; released++; release(); };
        cleanupReleases.add(finish); retainArrived(); return finish;
      };
      const late = new Promise<InstanceType<typeof lsp.LspClient>>(resolve => { resolveLate = resolve; });
      const error = new Error("fixture preparation failed"), failed = Promise.reject(error); void failed.catch(() => { });
      const originalContext = LoadedPool.prototype.context;
      LoadedPool.prototype.context = function(this: InstanceType<typeof lsp.LspSessionPool>, ...args: Parameters<typeof originalContext>) {
        extensionPool = this;
        this.entries.set("failed", failed); this.entries.set(spec.bin + "@" + f.dir, late);
        return originalContext.apply(this, args);
      };
      restoreContext = () => { LoadedPool.prototype.context = originalContext; };
      const harness = await runnerFor(loaded.default, f.dir); runner = harness.runner;
      const controller = new AbortController(); let settled = false;
      started = true;
      const tool = toolCall("lsp", { action: "diagnostics", file: "*" }, harness.tools, controller.signal).then(value => { settled = true; return value; }); calls.push(tool);
      await waitFor(() => extensionPool !== undefined);
      if (cancel) {
        const start = Date.now(); controller.abort();
        const cancelled = await tool; assert.equal(cancelled.isError, true); assert.match(JSON.stringify(cancelled), /cancel/i);
        assert.ok(Date.now() - start < 500, "Deferred preparation must cancel promptly");
        resolveLate(client);
      } else {
        await sleep(40); assert.equal(settled, false, "A failed preparation cannot finish the scope before the deferred preparation settles");
        assert.equal(retained, 0); assert.equal(released, 0);
        resolveLate(client);
        const failure = await tool; assert.equal(failure.isError, true); assert.match(JSON.stringify(failure), /fixture preparation failed/);
        assert.equal(retained, 1); assert.equal(released, 1, "Late preparation must be released with the failed tool");
      }
      restoreContext();
      await late;
      assert.equal(retained, released);
      await fs.writeFile(file, "changed\n");
      assert.ok(extensionPool);
      const freshness = extensionPool.getClient(spec, f.dir); calls.push(freshness);
      const successor = await Promise.race([freshness, sleep(1000).then(() => { throw new Error("Fixture freshness transition remained blocked by a retained acquisition"); })]);
      assert.notEqual(successor, client);
      await client.drainOperations();
      assert.equal(retained, released); assert.equal(cancel ? retained : released, cancel ? 0 : 1);
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 2);
    } finally {
      restoreContext(); if (client) resolveLate(client);
      if (started && !cancel) await retainedArrival;
      for (const release of [...cleanupReleases]) release();
      await runner?.emit({ type: "session_shutdown", reason: "quit" });
      await ownerPool?.shutdown("quit", "fixture-owner"); await Promise.allSettled(calls); await f.close();
    }
  });
}

test("R8 cancelled post-edit command preserves its reserved diagnostic successor and every group owner", async () => {
  const f = await fixture(), calls: Promise<unknown>[] = [], controller = new AbortController();
  let runner: InstanceType<typeof ExtensionRunner> | undefined, restoreContext = () => { };
  let pool: InstanceType<typeof lsp.LspSessionPool> | undefined;
  try {
    await fs.writeFile(join(f.dir, "file.ts"), 'export const result = "amber";\nreslt;\n');
    const harness = await freshnessLsp(f.dir); runner = harness.runner;
    const loaded = await fixtureImport(pathToFileURL(join(f.dir, "freshness.ts")).href);
    const LoadedPool: typeof lsp.LspSessionPool = loaded.LspSessionPool, context = LoadedPool.prototype.context;
    LoadedPool.prototype.context = function(this: InstanceType<typeof lsp.LspSessionPool>, ...args: Parameters<typeof context>) {
      pool = this; return context.apply(this, args);
    };
    restoreContext = () => { LoadedPool.prototype.context = context; };
    assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
    assert.ok(pool); assert.equal(pool.entries.size, 1);
    const entry = [...pool.entries][0]; assert.ok(entry); const [key, original] = entry;
    const predecessor = await original;
    await fs.writeFile(join(f.dir, "hold-command"), "");
    const apply = toolCall("lsp", { action: "code_actions", file: "file.ts", line: 2, query: "Change spelling", apply: true }, harness.tools, controller.signal); calls.push(apply);
    await waitFor(() => existsSync(join(f.dir, "command-held")));
    assert.doesNotMatch(await fs.readFile(join(f.dir, "file.ts"), "utf8"), /reslt/);
    const diagnostics = toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools); calls.push(diagnostics);
    await waitFor(() => pool?.entries.get(key) !== original);
    const reservation = pool.entries.get(key); assert.ok(reservation);
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1);
    controller.abort(); const cancelled = await apply;
    assert.equal(cancelled.isError, true); assert.match(JSON.stringify(cancelled), /cancel|Abort/);
    const fresh = await diagnostics; assert.equal(fresh.isError, false); assert.doesNotMatch(JSON.stringify(fresh), /2552|reslt/);
    assert.equal(pool.entries.get(key), reservation, "Predecessor cancellation must preserve the successor reservation");
    const successor = await reservation; assert.notEqual(successor, predecessor);
    assert.equal(await pool.getClient(predecessor.spec, predecessor.projectRoot), successor);
    assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 2, "Ordinary lookup must not create an unowned third client");
    await runner.emit({ type: "session_shutdown", reason: "quit" });
    const births = records(f.events).filter(row => row.kind === "group_birth"), settled = records(f.events).filter(row => row.kind === "group_settled");
    assert.equal(settled.length, births.length); assert.ok(settled.every(row => row.ok === true));
    assert.deepEqual(settled.map(row => row.childPid).sort(), births.map(row => row.childPid).sort());
    assert.equal(records(f.events).find(row => row.kind === "shutdown_summary")?.ok, true);
  } finally {
    restoreContext(); controller.abort(); await fs.writeFile(join(f.dir, "release-command"), "");
    await runner?.emit({ type: "session_shutdown", reason: "quit" }); await Promise.allSettled(calls); await f.close();
  }
});

async function gatedGenerationLsp(dir: string) {
  const spec = await fakeLsp(dir);
  let peer = await fs.readFile(spec.bin, "utf8");
  peer = peer.replace("commands = {}", `generation_path = root + '/generation'
try:
    with open(generation_path) as inp: generation = int(inp.read()) + 1
except FileNotFoundError: generation = 1
with open(generation_path, 'w') as out: out.write(str(generation))
commands = {}`);
  peer = peer.replace("    if msg.get('method') == 'initialize':", `    if msg.get('method') == 'initialize':
        open(root + '/init-' + str(generation), 'w').close()
        while os.path.exists(root + '/hold-init-' + str(generation)) and not os.path.exists(root + '/release-init-' + str(generation)): time.sleep(.005)
        if os.path.exists(root + '/fail-init-' + str(generation)):
            send({'id': msg['id'], 'error': {'code': -32603, 'message': 'fixture generation ' + str(generation) + ' init failed'}})
            return`);
  await fs.writeFile(spec.bin, peer); return spec;
}

for (const failSuccessor of [false, true]) {
  test(`R8 stale exit callbacks cannot evict another initialization generation (successor fails=${failSuccessor})`, async () => {
    const f = await fixture(), pool = new lsp.LspSessionPool(), init = lsp.LspClient.prototype.init;
    const clients: InstanceType<typeof lsp.LspClient>[] = [], calls: Promise<unknown>[] = [];
    try {
      lsp.LspClient.prototype.init = function(this: InstanceType<typeof lsp.LspClient>) {
        if (this.projectRoot === f.dir) clients.push(this); return init.call(this);
      };
      const spec = await gatedGenerationLsp(f.dir), file = join(f.dir, "file.ts"), key = spec.bin + "@" + f.dir;
      await fs.writeFile(file, "x\n");
      const first = await pool.getClient(spec, f.dir); await first.ensureOpen(file, "typescript");
      const staleExit = first.onExit; assert.ok(staleExit);
      await fs.writeFile(file, "changed\n"); await fs.writeFile(join(f.dir, "hold-init-2"), "");
      if (failSuccessor) await fs.writeFile(join(f.dir, "fail-init-2"), "");
      const replacement = pool.getClient(spec, f.dir); void replacement.catch(() => { }); calls.push(replacement);
      await waitFor(() => existsSync(join(f.dir, "init-2")));
      const reservation = pool.entries.get(key); assert.ok(reservation);
      staleExit(); assert.equal(pool.entries.get(key), reservation);
      await fs.writeFile(join(f.dir, "release-init-2"), "");
      let successor: InstanceType<typeof lsp.LspClient>;
      if (failSuccessor) {
        await assert.rejects(replacement, /fixture generation 2 init failed/);
        assert.equal(pool.entries.has(key), false, "Failed successor initialization must evict its own reservation");
        await fs.writeFile(join(f.dir, "hold-init-3"), "");
        const following = pool.getClient(spec, f.dir); calls.push(following);
        await waitFor(() => existsSync(join(f.dir, "init-3")));
        const nextReservation = pool.entries.get(key); assert.ok(nextReservation);
        const failedExit = clients[1].onExit; assert.ok(failedExit); failedExit(); staleExit();
        assert.equal(pool.entries.get(key), nextReservation, "Old and failed-generation callbacks cannot evict the new initializer");
        await fs.writeFile(join(f.dir, "release-init-3"), ""); successor = await following;
      } else { successor = await replacement; }
      assert.notEqual(successor, first); assert.equal(await pool.getClient(spec, f.dir), successor);
      await pool.shutdown("quit", "fixture");
      const births = records(f.events).filter(row => row.kind === "group_birth"), settled = records(f.events).filter(row => row.kind === "group_settled");
      assert.equal(births.length, failSuccessor ? 3 : 2); assert.equal(settled.length, births.length); assert.ok(settled.every(row => row.ok === true));
      assert.deepEqual(settled.map(row => row.childPid).sort(), births.map(row => row.childPid).sort());
    } finally {
      lsp.LspClient.prototype.init = init;
      await fs.writeFile(join(f.dir, "release-init-2"), ""); await fs.writeFile(join(f.dir, "release-init-3"), "");
      await pool.shutdown("quit", "fixture"); await Promise.allSettled(calls); await f.close();
    }
  });
}

test("R8 dropped freshness reservation cannot install a successor into an unowned slot", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool(), calls: Promise<unknown>[] = []; let release = () => { };
  try {
    const spec = await fakeLsp(f.dir), file = join(f.dir, "file.ts"), key = spec.bin + "@" + f.dir;
    await fs.writeFile(file, "x\n"); const first = await pool.getClient(spec, f.dir); await first.ensureOpen(file, "typescript");
    release = first.retainOperation(); await fs.writeFile(file, "changed\n");
    const original = pool.entries.get(key), replacement = pool.getClient(spec, f.dir); void replacement.catch(() => { }); calls.push(replacement);
    await waitFor(() => pool.entries.get(key) !== original);
    assert.equal((await pool.dropClient(key))?.ok, true); release();
    await assert.rejects(replacement, /acquisition superseded/);
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1, "A removed reservation cannot birth a successor");
    const second = await pool.getClient(spec, f.dir); assert.notEqual(second, first); assert.equal(await pool.getClient(spec, f.dir), second);
    await pool.shutdown("quit", "fixture");
    const births = records(f.events).filter(row => row.kind === "group_birth"), settled = records(f.events).filter(row => row.kind === "group_settled");
    assert.equal(births.length, 2); assert.equal(settled.length, births.length); assert.ok(settled.every(row => row.ok === true));
  } finally { release(); await pool.shutdown("quit", "fixture"); await Promise.allSettled(calls); await f.close(); }
});

for (const [firstAction, secondAction, cancelSecond] of [
  ["symbols", "symbols", false], ["diagnostics", "diagnostics", false],
  ["symbols", "diagnostics", false], ["diagnostics", "symbols", false],
  ["symbols", "symbols", true], ["diagnostics", "diagnostics", true],
] satisfies Array<["symbols" | "diagnostics", "symbols" | "diagnostics", boolean]>) {
  test(`R9 overlapping ${firstAction}/${secondAction} batches settle after opposite reads and edits (cancelled=${cancelSecond})`, async () => {
    const f = await fixture(), originalRead = fs.readFile, calls: Promise<unknown>[] = [];
    const controllers = [new AbortController(), new AbortController()];
    let runner: InstanceType<typeof ExtensionRunner> | undefined, restoreContext = () => { }, restoreRetain = () => { };
    let releaseReads = () => { }, retained = 0, released = 0;
    try {
      const tsFile = join(f.dir, "file.ts"), goFile = join(f.dir, "file.go");
      await fs.writeFile(tsFile, "initial\n"); await fs.writeFile(goFile, "initial\n");
      const peer = `#!${fixturePython}
import json, sys
def send(frame):
    body = json.dumps(frame).encode()
    sys.stdout.buffer.write(('Content-Length: ' + str(len(body)) + '\\r\\n\\r\\n').encode() + body)
    sys.stdout.buffer.flush()
while True:
    header = sys.stdin.buffer.readline()
    if not header: break
    size = int(header.split(b':')[1]); assert sys.stdin.buffer.readline() == b'\\r\\n'
    msg = json.loads(sys.stdin.buffer.read(size)); method = msg.get('method')
    if method == 'initialize': send({'id': msg['id'], 'result': {'capabilities': {}}})
    if method == 'textDocument/didOpen':
        doc = msg['params']['textDocument']
        send({'method': 'textDocument/publishDiagnostics', 'params': {'uri': doc['uri'], 'diagnostics': [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'fixture current error: ' + doc['text'].strip(), 'severity': 1}]}})
    if method == 'workspace/symbol': send({'id': msg['id'], 'result': [{'name': 'fixture symbol', 'kind': 13}]})
`;
      const tsBin = join(f.dir, "a-ts-peer"), goBin = join(f.dir, "b-go-peer");
      await fs.writeFile(tsBin, peer, { mode: 0o700 }); await fs.writeFile(goBin, peer, { mode: 0o700 });
      await enableCompletedTsPeer(tsBin);
      const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8"), modulePath = join(f.dir, "batch.ts");
      await fs.writeFile(modulePath, raw.replace("___TS_LSP___", tsBin).replace("___GOLANG_LSP___", goBin)
        .replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts"))));
      const loaded = await fixtureImport(pathToFileURL(modulePath).href);
      const LoadedPool: typeof lsp.LspSessionPool = loaded.LspSessionPool, LoadedClient: typeof lsp.LspClient = loaded.LspClient;
      let pool: InstanceType<typeof lsp.LspSessionPool> | undefined;
      const originalContext = LoadedPool.prototype.context;
      LoadedPool.prototype.context = function(...args: Parameters<typeof originalContext>) {
        pool = this; return originalContext.apply(this, args);
      };
      restoreContext = () => { LoadedPool.prototype.context = originalContext; };
      const originalRetain = LoadedClient.prototype.retainOperation;
      LoadedClient.prototype.retainOperation = function() {
        retained++; const finish = originalRetain.call(this); let done = false;
        return () => { if (done) return; done = true; released++; finish(); };
      };
      restoreRetain = () => { LoadedClient.prototype.retainOperation = originalRetain; };
      const harness = await runnerFor(loaded.default, f.dir); runner = harness.runner;
      await toolCall("lsp", { action: "status" }, harness.tools); restoreContext(); assert.ok(pool);
      const ts = await pool.getClient({ bin: tsBin, args: [], languageId: "typescript", name: "fixture-ts" }, f.dir);
      const go = await pool.getClient({ bin: goBin, args: [], languageId: "go", name: "fixture-go" }, f.dir);
      await ts.ensureOpen(tsFile, "typescript"); await go.ensureOpen(goFile, "go");
      let tsReads = 0, goReads = 0;
      const gate = new Promise<void>(resolve => { releaseReads = resolve; });
      Object.defineProperty(fs, "readFile", { value: async (...args: Parameters<typeof fs.readFile>) => {
        if (args[0] === tsFile && ++tsReads === 2) await gate;
        if (args[0] === goFile && ++goReads === 1) await gate;
        return originalRead(...args);
      } }); syncBuiltinESMExports();
      const first = toolCall("lsp", { action: firstAction, file: "*", query: "fixture" }, harness.tools, controllers[0].signal); calls.push(first);
      await waitFor(() => goReads === 1);
      const second = toolCall("lsp", { action: secondAction, file: "*", query: "fixture" }, harness.tools, controllers[1].signal); calls.push(second);
      await waitFor(() => tsReads === 2);
      // These external events do not wait for B's Go acquisition: ordered
      // preparation deliberately defers that read until B's TypeScript settles.
      await fs.writeFile(tsFile, "changed ts\n"); await fs.writeFile(goFile, "changed go\n");
      if (cancelSecond) {
        const start = Date.now(); controllers[1].abort();
        const cancelled = await second; assert.equal(cancelled.isError, true); assert.match(JSON.stringify(cancelled), /cancel/i);
        assert.ok(Date.now() - start < 500, "Batch preparation cancellation must settle promptly");
      }
      releaseReads();
      const results = await Promise.race([Promise.all([first, second]), sleep(1500).then(() => { throw new Error("Released workspace batch remained in an acquisition cycle"); })]);
      for (const [index, action] of [firstAction, secondAction].entries()) {
        if (cancelSecond && index === 1) continue;
        const result = results[index];
        if (action === "symbols") { assert.equal(result.isError, false); assert.match(JSON.stringify(result), /2 symbol\(s\)/); }
        else {
          assert.match(JSON.stringify(result), /fixture current error|diagnostics_unconfirmed|TypeScript diagnostics unconfirmed/);
          if (/unconfirmed/.test(JSON.stringify(result))) assert.equal(result.isError, true);
          assert.doesNotMatch(JSON.stringify(result), /No diagnostics across open files|file is clean/);
        }
      }
      assert.equal(retained, released, "Every acquired workflow retention must be released");
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      const births = records(f.events).filter(row => row.kind === "group_birth");
      const settled = records(f.events).filter(row => row.kind === "group_settled");
      assert.ok(births.length > 2, "Changed-disk acquisitions must actually construct fresh clients");
      assert.equal(settled.length, births.length); assert.ok(settled.every(row => row.ok === true));
      assert.equal(pool.entries.size, 0);
    } finally {
      controllers.forEach(controller => controller.abort()); releaseReads();
      Object.defineProperty(fs, "readFile", { value: originalRead }); syncBuiltinESMExports(); restoreContext();
      await runner?.emit({ type: "session_shutdown", reason: "quit" }); await Promise.allSettled(calls);
      restoreRetain(); await f.close();
    }
  });
}

async function removedDocumentLsp(dir: string) {
  const binary = join(dir, "removed-document-peer");
  await fs.writeFile(binary, `#!${fixturePython}
import json, os, sys
root = ${JSON.stringify(dir)}
docs = {}
command_id = None
def send(frame):
    body = json.dumps(frame).encode()
    sys.stdout.buffer.write(('Content-Length: ' + str(len(body)) + '\\r\\n\\r\\n').encode() + body)
    sys.stdout.buffer.flush()
def resource(kind):
    old = 'file://' + root + '/a.ts'
    return {'documentChanges': [{'kind': 'delete', 'uri': old} if kind == 'delete' else {'kind': 'rename', 'oldUri': old, 'newUri': 'file://' + root + '/moved.ts'}]}
while True:
    header = sys.stdin.buffer.readline()
    if not header: break
    size = int(header.split(b':')[1]); assert sys.stdin.buffer.readline() == b'\\r\\n'
    msg = json.loads(sys.stdin.buffer.read(size)); method = msg.get('method'); params = msg.get('params', {})
    if method == 'initialize': send({'id': msg['id'], 'result': {'capabilities': {'codeActionProvider': True}}})
    if method == 'textDocument/didOpen':
        doc = params['textDocument']; docs[doc['uri']] = doc
        changed = doc['uri'].endswith('/b.ts') and not os.path.exists(root + '/a.ts')
        diags = [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'confirmed removed dependency', 'severity': 1}] if changed else []
        frame = {'method': 'textDocument/publishDiagnostics', 'params': {'uri': doc['uri'], 'version': doc['version'], 'diagnostics': diags}}
        send(frame)
        with open(root + '/resource-publications.jsonl', 'a') as out: out.write(json.dumps({'pid': os.getpid(), **frame['params']}) + '\\n')
    if method == 'textDocument/didClose':
        docs.pop(params['textDocument']['uri'], None)
        with open(root + '/resource-closes.jsonl', 'a') as out: out.write(json.dumps(params['textDocument']) + '\\n')
        for uri in docs: send({'method': 'textDocument/publishDiagnostics', 'params': {'uri': uri, 'diagnostics': []}})
    if method == 'textDocument/codeAction':
        send({'id': msg['id'], 'result': [
            {'title': 'remove-file', 'edit': resource('delete')}, {'title': 'move-file', 'edit': resource('rename')},
            {'title': 'command-remove', 'command': {'title': 'remove', 'command': '_typescript.applyCodeActionCommand', 'arguments': ['delete']}},
            {'title': 'command-move', 'command': {'title': 'move', 'command': '_typescript.applyCodeActionCommand', 'arguments': ['rename']}}]})
    if method == 'workspace/executeCommand':
        command_id = msg['id']; send({'id': 900, 'method': 'workspace/applyEdit', 'params': {'edit': resource(params['arguments'][0])}})
    if msg.get('id') == 900:
        with open(root + '/resource-ack.json', 'w') as out: json.dump(msg, out)
        send({'id': command_id, 'result': None})
    if method == 'workspace/symbol': send({'id': msg['id'], 'result': [{'name': 'surviving b', 'kind': 13}]})
`, { mode: 0o700 });
  await enableCompletedTsPeer(binary);
  const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8"), modulePath = join(dir, "removed-document.ts");
  await fs.writeFile(modulePath, raw.replace("___TS_LSP___", binary)
    .replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts"))));
  const loaded = await fixtureImport(pathToFileURL(modulePath).href), LoadedPool: typeof lsp.LspSessionPool = loaded.LspSessionPool;
  let pool: InstanceType<typeof lsp.LspSessionPool> | undefined;
  const originalContext = LoadedPool.prototype.context;
  LoadedPool.prototype.context = function(...args: Parameters<typeof originalContext>) { pool = this; return originalContext.apply(this, args); };
  let harness: Awaited<ReturnType<typeof runnerFor>>;
  try { harness = await runnerFor(loaded.default, dir); await toolCall("lsp", { action: "status" }, harness.tools); }
  finally { LoadedPool.prototype.context = originalContext; }
  assert.ok(pool);
  return { ...harness, pool };
}

for (const operation of ["remove-file", "move-file", "command-remove", "command-move", "external", "restoration-race"]) {
  test(`R10 first surviving-file and workspace queries succeed after ${operation}`, async () => {
    const f = await fixture(), originalRead = fs.readFile;
    let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      const removed = join(f.dir, "a.ts"), surviving = join(f.dir, "b.ts"), uri = pathToFileURL(removed).href;
      await fs.writeFile(removed, "a\n"); await fs.writeFile(surviving, "b\n");
      const harness = await removedDocumentLsp(f.dir); runner = harness.runner;
      for (const file of ["a.ts", "b.ts"]) assert.equal((await toolCall("lsp", { action: "diagnostics", file }, harness.tools)).isError, false);
      const predecessor = await [...harness.pool.entries.values()][0]; assert.ok(predecessor);
      if (operation === "external") await fs.rm(removed);
      else if (operation === "restoration-race") {
        await fs.writeFile(surviving, "changed b\n"); let reads = 0;
        Object.defineProperty(fs, "readFile", { value: async (...args: Parameters<typeof fs.readFile>) => {
          if (args[0] === removed && ++reads === 2) await fs.rm(removed);
          return originalRead(...args);
        } }); syncBuiltinESMExports();
      } else {
        const selector = String(["remove-file", "move-file", "command-remove", "command-move"].indexOf(operation));
        const applied = await toolCall("lsp", { action: "code_actions", file: "b.ts", line: 1, query: selector, apply: true }, harness.tools);
        assert.equal(applied.isError, false); assert.equal(existsSync(removed), false);
        assert.equal(predecessor.openDocuments().some(doc => doc.filepath === removed), false, "Confirmed resource operations must relinquish the old document immediately");
        if (operation === "move-file" || operation === "command-move") assert.equal(await fs.readFile(join(f.dir, "moved.ts"), "utf8"), "a\n");
      }
      const first = await toolCall("lsp", { action: "diagnostics", file: "b.ts" }, harness.tools);
      assert.equal(first.isError, false, JSON.stringify(first)); assert.match(JSON.stringify(first), /confirmed removed dependency/);
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 2, "The first valid query needs at most one owned successor, without retry");
      if (operation !== "restoration-race") assert.equal(predecessor.openDocuments().some(doc => doc.filepath === removed), false);
      const symbols = await toolCall("lsp", { action: "symbols", file: "*", query: "surviving" }, harness.tools);
      assert.equal(symbols.isError, false); assert.match(JSON.stringify(symbols), /surviving b/);
      const workspace = await toolCall("lsp", { action: "diagnostics", file: "*" }, harness.tools);
      assert.equal(workspace.isError, false); assert.match(JSON.stringify(workspace), /confirmed removed dependency/);
      assert.doesNotMatch(JSON.stringify(workspace), /No diagnostics across open files/);
      const current = await [...harness.pool.entries.values()][0]; assert.ok(current);
      assert.notEqual(current, predecessor); assert.equal(current.hasDiagnosticsFor(pathToFileURL(surviving).href), true);
      assert.equal(current.openDocuments().some(doc => doc.filepath === removed), false);
      const missing = await toolCall("lsp", { action: "diagnostics", file: "a.ts" }, harness.tools);
      assert.equal(missing.isError, true); assert.match(JSON.stringify(missing), /ENOENT|cannot read/);
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 2);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      const births = records(f.events).filter(row => row.kind === "group_birth"), settled = records(f.events).filter(row => row.kind === "group_settled");
      assert.equal(settled.length, births.length); assert.ok(settled.every(row => row.ok === true)); assert.equal(harness.pool.entries.size, 0);
    } finally { Object.defineProperty(fs, "readFile", { value: originalRead }); syncBuiltinESMExports(); await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

for (const operation of ["remove-file", "move-file"]) for (const failure of [false, true]) {
  test(`R10 ${operation} ${failure ? "failed filesystem effect" : "preview"} keeps the live document`, async () => {
    const f = await fixture(), originalRm = fs.rm, originalRename = fs.rename;
    let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      const removed = join(f.dir, "a.ts"); await fs.writeFile(removed, "a\n"); await fs.writeFile(join(f.dir, "b.ts"), "b\n");
      const harness = await removedDocumentLsp(f.dir); runner = harness.runner;
      for (const file of ["a.ts", "b.ts"]) assert.equal((await toolCall("lsp", { action: "diagnostics", file }, harness.tools)).isError, false);
      const client = await [...harness.pool.entries.values()][0]; assert.ok(client);
      if (failure) {
        const denied = () => Promise.reject(Object.assign(new Error("EACCES: fixture resource effect denied"), { code: "EACCES" }));
        Object.defineProperty(fs, operation === "remove-file" ? "rm" : "rename", { value: denied }); syncBuiltinESMExports();
      }
      const result = await toolCall("lsp", { action: "code_actions", file: "b.ts", line: 1, query: operation === "remove-file" ? "0" : "1", apply: failure }, harness.tools);
      assert.equal(result.isError, failure); if (failure) assert.match(JSON.stringify(result), /EACCES/);
      assert.equal(await fs.readFile(removed, "utf8"), "a\n"); assert.equal(existsSync(join(f.dir, "moved.ts")), false);
      assert.equal(client.openDocuments().some(doc => doc.filepath === removed), true);
      assert.equal(records(join(f.dir, "resource-closes.jsonl")).some(row => row.uri === pathToFileURL(removed).href), false);
      Object.defineProperty(fs, "rm", { value: originalRm }); Object.defineProperty(fs, "rename", { value: originalRename }); syncBuiltinESMExports();
      assert.equal((await toolCall("lsp", { action: "diagnostics", file: "a.ts" }, harness.tools)).isError, false);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      const births = records(f.events).filter(row => row.kind === "group_birth"), settled = records(f.events).filter(row => row.kind === "group_settled");
      assert.equal(births.length, failure ? 2 : 1); assert.equal(settled.length, births.length); assert.ok(settled.every(row => row.ok === true));
    } finally {
      Object.defineProperty(fs, "rm", { value: originalRm }); Object.defineProperty(fs, "rename", { value: originalRename }); syncBuiltinESMExports();
      await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close();
    }
  });
}

for (const phase of ["scan", "restoration"]) for (const code of ["EACCES", "EIO", undefined]) {
  test(`R10 ${phase} preserves ${code ?? "unknown string-only ENOENT"} read failure and owned cleanup`, async () => {
    const f = await fixture(), originalRead = fs.readFile;
    let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      const removed = join(f.dir, "a.ts"), surviving = join(f.dir, "b.ts"); await fs.writeFile(removed, "a\n"); await fs.writeFile(surviving, "b\n");
      const harness = await removedDocumentLsp(f.dir); runner = harness.runner;
      for (const file of ["a.ts", "b.ts"]) assert.equal((await toolCall("lsp", { action: "diagnostics", file }, harness.tools)).isError, false);
      const predecessor = await [...harness.pool.entries.values()][0]; assert.ok(predecessor);
      const fault = code ? Object.assign(new Error(code + ": fixture read failure"), { code }) : new Error("ENOENT words without an error code");
      let reads = 0;
      if (phase === "restoration") await fs.writeFile(surviving, "changed b\n");
      Object.defineProperty(fs, "readFile", { value: async (...args: Parameters<typeof fs.readFile>) => {
        if (args[0] === removed && ++reads >= (phase === "scan" ? 1 : 2)) throw fault;
        return originalRead(...args);
      } }); syncBuiltinESMExports();
      const originalGet = harness.pool.getClient.bind(harness.pool); let observed: unknown;
      harness.pool.getClient = async (...args: Parameters<typeof originalGet>) => {
        try { return await originalGet(...args); } catch (error) { observed = error; throw error; }
      };
      const failure = await toolCall("lsp", { action: "diagnostics", file: "b.ts" }, harness.tools);
      assert.equal(failure.isError, true); assert.match(JSON.stringify(failure), new RegExp(fault.message));
      assert.ok(observed instanceof Error);
      if (phase === "restoration") assert.equal(observed.cause, fault); else assert.equal(observed, fault);
      assert.equal(predecessor.openDocuments().some(doc => doc.filepath === removed), true, "Non-ENOENT failure must not relinquish a document");
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, phase === "restoration" ? 2 : 1);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      const births = records(f.events).filter(row => row.kind === "group_birth"), settled = records(f.events).filter(row => row.kind === "group_settled");
      assert.equal(settled.length, births.length); assert.ok(settled.every(row => row.ok === true)); assert.equal(harness.pool.entries.size, 0);
    } finally { Object.defineProperty(fs, "readFile", { value: originalRead }); syncBuiltinESMExports(); await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

async function semanticTsPeer(dir: string, mode: string, responseOverride?: { body: unknown; envelope: string }) {
  const binary = join(dir, "complete-semantics-peer");
  await fs.writeFile(binary, `#!${fixturePython}
import json, os, sys, threading, time
root, mode = ${JSON.stringify(dir)}, ${JSON.stringify(mode)}
response_override = json.loads(${JSON.stringify(JSON.stringify(responseOverride ?? null))})
docs, commands = {}, []
semantic_complete, semantic_server = False, False
lock = threading.Lock()
def send(frame):
    body = json.dumps(frame).encode()
    with lock:
        sys.stdout.buffer.write(('Content-Length: ' + str(len(body)) + '\\r\\n\\r\\n').encode() + body); sys.stdout.buffer.flush()
def complete(msg):
    global semantic_complete
    command, args = msg['params']['arguments'][:2]
    if command == 'semanticDiagnosticsSync' and mode in ('held', 'revision'):
        open(root + '/held', 'w').close()
        while not os.path.exists(root + '/release'): time.sleep(.005)
    if mode == 'rpc-error': send({'id': msg['id'], 'error': {'code': -32603, 'message': 'fixture complete RPC failure'}}); return
    body = []
    if mode in ('errors', 'readonly'):
        kinds = {'syntacticDiagnosticsSync': [(1005, 'error', 'fixture syntax error')],
                 'semanticDiagnosticsSync': [(2322, 'error', 'Type number is not assignable to ExtensionAPI'), (2307, 'error', 'Cannot find module pinned SDK')],
                 'suggestionDiagnosticsSync': [(6133, 'suggestion', 'fixture unused declaration')]}
        body = [{'start': {'line': 1, 'offset': 1}, 'end': {'line': 1, 'offset': 2}, 'text': text, 'code': code, 'category': category} for code, category, text in kinds[command]]
    response = {'type': 'response', 'command': command, 'success': True, 'body': body}
    if mode == 'failed': response = {**response, 'success': False, 'message': 'fixture completed semantic failure'}
    if mode == 'missing-body': response.pop('body')
    if mode == 'wrong-command': response['command'] = 'geterr'
    if mode == 'wrong-type': response['type'] = 'event'
    if mode in ('bad-range', 'bad-category'):
        response['body'] = [{'start': {'line': 0 if mode == 'bad-range' else 1, 'offset': 1}, 'end': {'line': 1, 'offset': 2}, 'text': 'bad', 'code': 2322, 'category': 'unexpected' if mode == 'bad-category' else 'error'}]
    if mode == 'readonly' and command == 'semanticDiagnosticsSync':
        uri = 'file://' + args['file']
        send({'id': 900, 'method': 'workspace/applyEdit', 'params': {'edit': {'changes': {uri: [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'newText': 'MUTATION'}]}}}})
    if command == 'semanticDiagnosticsSync': semantic_complete = True
    frame = {'id': msg['id'], 'result': response}
    if response_override is not None and command == 'semanticDiagnosticsSync':
        response['body'] = response_override['body']
        envelope = response_override['envelope']
        errors = {'false': False, 'zero': 0, 'null': None, 'string': 'bad error', 'missing-code': {'message': 'bad'},
                  'missing-message': {'code': -32603}, 'fractional-code': {'code': -1.5, 'message': 'bad'},
                  'string-code': {'code': '-32603', 'message': 'bad'}, 'valid': {'code': -32603, 'message': 'fixture r13 valid error'}}
        if envelope.startswith('conflict-'): frame['error'] = errors[envelope[len('conflict-'):]]
        elif envelope.startswith('error-'): frame = {'id': msg['id'], 'error': errors[envelope[len('error-'):]]}
        elif envelope == 'missing': frame = {'id': msg['id']}
    send(frame)
    for uri in docs: send({'method': 'textDocument/publishDiagnostics', 'params': {'uri': uri, 'diagnostics': []}})
def consumer_response(msg):
    method = msg['method']
    if (mode.startswith('r14-consumer-') and method != 'codeAction/resolve') or (method == 'codeAction/resolve' and mode.startswith('r14-resolve-')):
        marker = 'resolve' if method == 'codeAction/resolve' else 'consumer'
        open(root + '/' + marker + '-held', 'w').close()
        while not os.path.exists(root + '/release-' + marker): time.sleep(.005)
    shape = mode.rsplit('-', 1)[-1]
    uri = next(iter(docs))
    edit = {'changes': {uri: [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'newText': 'EDIT'}]}}
    command = {'title': 'fixture command', 'command': 'r15-follow' if mode.startswith('r15-') else 'r14-follow', 'arguments': [uri]}
    action = {'title': 'fixture action', 'edit': edit, 'command': command}
    if method == 'textDocument/hover': result = None if shape == 'empty' else {'contents': 'fixture current interface'}
    elif method == 'codeAction/resolve':
        with open(root + '/resolve-dispatched', 'w') as out: out.write('yes')
        if mode.startswith('r15-'):
            send({'id': msg['id'], 'error': {'code': -32603, 'message': 'offline resolve failed'}}); return
        result = action
    elif mode.startswith('r15-'): result = [{'title': 'fixture action', 'data': {}, **({'command': command} if shape == 'command' else {})}]
    else: result = [] if shape == 'empty' else [command if shape == 'command' else {'title': 'fixture action', 'data': {}} if shape == 'deferred' else action]
    send({'id': msg['id'], 'result': result})
def authorized_command(msg):
    params = msg['params']; command = params['command']
    with open(root + '/command-dispatches.jsonl', 'a') as out: out.write(json.dumps(params) + '\\n')
    if command == 'r14-block':
        open(root + '/block-held', 'w').close()
        while not os.path.exists(root + '/release-block'): time.sleep(.005)
    else:
        uri = params['arguments'][0]
        with open(uri[len('file://'):]) as inp: width = len(inp.readline().rstrip('\\r\\n'))
        send({'id': 901, 'method': 'workspace/applyEdit', 'params': {'edit': {'changes': {uri: [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': width}}, 'newText': 'FOLLOW'}]}}}})
        while not os.path.exists(root + '/ack-901'): time.sleep(.005)
    send({'id': msg['id'], 'result': None})
while True:
    header = sys.stdin.buffer.readline()
    if not header: break
    size = int(header.split(b':')[1]); assert sys.stdin.buffer.readline() == b'\\r\\n'
    msg = json.loads(sys.stdin.buffer.read(size)); method = msg.get('method'); params = msg.get('params', {})
    if method == 'initialize':
        semantic_server = params.get('initializationOptions', {}).get('tsserver', {}).get('useSyntaxServer') == 'never'
        with open(root + '/initialization.json', 'w') as out: json.dump(params, out)
        send({'id': msg['id'], 'result': {'capabilities': {'executeCommandProvider': {'commands': [] if mode == 'unsupported' else ['typescript.tsserverRequest']}, 'codeActionProvider': {'resolveProvider': not mode.startswith('r15-no-resolve-')} if mode.startswith(('r14-', 'r15-')) else True, 'hoverProvider': True}}})
    if method == 'textDocument/didOpen':
        doc = params['textDocument']; docs[doc['uri']] = doc
        send({'method': 'textDocument/publishDiagnostics', 'params': {'uri': doc['uri'], 'diagnostics': []}}); open(root + '/opened', 'w').close()
    if method == 'workspace/executeCommand':
        with open(root + '/semantic-requests.jsonl', 'a') as out: out.write(json.dumps(params) + '\\n')
        threading.Thread(target=complete if params.get('command') == 'typescript.tsserverRequest' else authorized_command, args=(msg,), daemon=True).start()
    if method == 'textDocument/codeAction':
        with open(root + '/code-action-context.json', 'w') as out: json.dump(params['context'], out)
        if mode.startswith(('r14-', 'r15-')): threading.Thread(target=consumer_response, args=(msg,), daemon=True).start()
        else: send({'id': msg['id'], 'result': []})
    if method == 'textDocument/hover':
        if mode.startswith(('r14-', 'r15-')): threading.Thread(target=consumer_response, args=(msg,), daemon=True).start()
        else: send({'id': msg['id'], 'result': {'contents': '(alias) interface ExtensionAPI' if semantic_server and semantic_complete else 'import ExtensionAPI'}})
    if method == 'codeAction/resolve': threading.Thread(target=consumer_response, args=(msg,), daemon=True).start()
    if msg.get('id') == 901: open(root + '/ack-901', 'w').close()
    if method in ('fixture/resultNull', 'fixture/validError', 'fixture/emptyMessage'):
        with open(root + '/rpc-controls.jsonl', 'a') as out: out.write(json.dumps(msg) + '\\n')
        frame = {'id': msg['id'], 'result': None} if method == 'fixture/resultNull' else {'id': msg['id'], 'error': {'code': -32603, 'message': '' if method == 'fixture/emptyMessage' else 'fixture r13 valid error'}}
        send(frame)
    if msg.get('id') == 900:
        with open(root + '/readonly-ack.json', 'w') as out: json.dump(msg, out)
`, { mode: 0o700 });
  const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8"), modulePath = join(dir, "complete-semantics.ts");
  await fs.writeFile(modulePath, raw.replace("___TS_LSP___", binary).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts"))));
  const loaded = await fixtureImport(pathToFileURL(modulePath).href), LoadedPool: typeof lsp.LspSessionPool = loaded.LspSessionPool;
  let pool: InstanceType<typeof lsp.LspSessionPool> | undefined;
  const originalContext = LoadedPool.prototype.context;
  LoadedPool.prototype.context = function(...args: Parameters<typeof originalContext>) { pool = this; return originalContext.apply(this, args); };
  let harness: Awaited<ReturnType<typeof runnerFor>>;
  try { harness = await runnerFor(loaded.default, dir); await toolCall("lsp", { action: "status" }, harness.tools); }
  finally { LoadedPool.prototype.context = originalContext; }
  assert.ok(pool); return { ...harness, pool };
}

for (const mode of ["errors", "clean"]) {
  test(`R12 actual consumers use completed TS diagnostics for file/workspace/code actions (${mode})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      await fs.writeFile(join(f.dir, "file.ts"), "const api: ExtensionAPI = 17;\n");
      const harness = await semanticTsPeer(f.dir, mode); runner = harness.runner;
      const first = await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools);
      assert.equal(first.isError, false);
      if (mode === "errors") { assert.match(JSON.stringify(first), /2322/); assert.match(JSON.stringify(first), /2307/); assert.match(JSON.stringify(first), /1005/); assert.match(JSON.stringify(first), /6133/); }
      else assert.match(JSON.stringify(first), /file is clean/);
      const requests = records(join(f.dir, "semantic-requests.jsonl"));
      assert.deepEqual(requests.slice(0, 3).map(record => Array.isArray(record.arguments) ? record.arguments[0] : null), ["syntacticDiagnosticsSync", "semanticDiagnosticsSync", "suggestionDiagnosticsSync"]);
      const workspace = await toolCall("lsp", { action: "diagnostics", file: "*" }, harness.tools);
      assert.equal(workspace.isError, false); if (mode === "errors") assert.match(JSON.stringify(workspace), /2322/);
      await toolCall("lsp", { action: "code_actions", file: "file.ts", line: 1, apply: false }, harness.tools);
      const context: unknown = JSON.parse(await fs.readFile(join(f.dir, "code-action-context.json"), "utf8")); assert.ok(lifecycle.isRecord(context));
      assert.ok(Array.isArray(context.diagnostics)); assert.equal(context.diagnostics.length, mode === "errors" ? 4 : 0);
      const executeTool: ExtensionToolContext["executeTool"] = (name, args, options) => { assert.ok(isJsonObject(args)); return toolCall(name, args, harness.tools, options?.signal); };
      const ctx: ExtensionToolContext = Object.assign(runner.createContext(), { tools: harness.tools, executeTool });
      const code = await executeCodemode("r12-complete", { code: 'return await tools.lsp({action:"diagnostics",file:"file.ts"});' }, undefined, undefined, ctx);
      assert.notEqual(code.isError, true); if (mode === "errors") assert.match(JSON.stringify(code), /2322/);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(record => record.kind === "group_settled" && record.ok === true).length, 1);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

for (const mode of ["unsupported", "failed", "rpc-error", "missing-body", "wrong-command", "wrong-type", "bad-range", "bad-category"]) {
  test(`R12 incomplete TS evidence is an error despite early empty push (${mode})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      await fs.writeFile(join(f.dir, "file.ts"), "x\n"); const harness = await semanticTsPeer(f.dir, mode); runner = harness.runner;
      const result = await toolCall("lsp", { action: "diagnostics", file: "file.ts", timeout: 1 }, harness.tools);
      assert.equal(result.isError, true); assert.doesNotMatch(JSON.stringify(result), /file is clean/);
      assert.match(JSON.stringify(result), /unsupported|failure|Invalid|incomplete/);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

for (const outcome of ["cancel", "timeout", "document", "dependency"]) {
  test(`R12 complete TS evidence cannot survive ${outcome} while semantic request is held`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined; const abort = new AbortController(); let call: Promise<unknown> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n"); const harness = await semanticTsPeer(f.dir, "held"); runner = harness.runner;
      let settled = false;
      const pending = toolCall("lsp", { action: "diagnostics", file: "file.ts", timeout: 1 }, harness.tools, abort.signal).then(result => { settled = true; return result; }); call = pending;
      await waitFor(() => settled || existsSync(join(f.dir, "held")));
      if (outcome === "cancel") abort.abort();
      if (outcome === "document" || outcome === "dependency") {
        if (outcome === "document") await fs.writeFile(file, "changed\n");
        harness.pool.invalidate(pathToFileURL(outcome === "document" ? file : join(f.dir, "dependency.ts")).href);
        await fs.writeFile(join(f.dir, "release"), "");
      }
      const start = Date.now(), result = await pending;
      assert.equal(result.isError, true); assert.doesNotMatch(JSON.stringify(result), /file is clean/);
      if (outcome === "cancel") { assert.match(JSON.stringify(result), /cancel/i); assert.ok(Date.now() - start < 500); }
      if (outcome === "document" || outcome === "dependency") assert.match(JSON.stringify(result), /changed|unconfirmed/);
    } finally { abort.abort(); await fs.writeFile(join(f.dir, "release"), ""); await runner?.emit({ type: "session_shutdown", reason: "quit" }); if (call) await call; await f.close(); }
  });
}

test("R12 cold TS hover waits for completed semantics with the supported semantic-server configuration", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    await fs.writeFile(join(f.dir, "file.ts"), "import type { ExtensionAPI } from 'sdk';\n"); const harness = await semanticTsPeer(f.dir, "clean"); runner = harness.runner;
    const hover = await toolCall("lsp", { action: "hover", file: "file.ts", line: 1 }, harness.tools);
    assert.equal(hover.isError, false); assert.match(JSON.stringify(hover), /interface ExtensionAPI/);
    const initialization: unknown = JSON.parse(await fs.readFile(join(f.dir, "initialization.json"), "utf8")); assert.ok(lifecycle.isRecord(initialization));
    assert.deepEqual(initialization.initializationOptions, { tsserver: { useSyntaxServer: "never" } });
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

test("R12 completed diagnostics cannot authorize workspace applyEdit", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const file = join(f.dir, "file.ts"); await fs.writeFile(file, "original\n"); const harness = await semanticTsPeer(f.dir, "readonly"); runner = harness.runner;
    const result = await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools); assert.equal(result.isError, false);
    await waitFor(() => existsSync(join(f.dir, "readonly-ack.json")));
    const ack: unknown = JSON.parse(await fs.readFile(join(f.dir, "readonly-ack.json"), "utf8")); assert.ok(lifecycle.isRecord(ack) && lifecycle.isRecord(ack.result));
    assert.equal(ack.result.applied, false); assert.equal(await fs.readFile(file, "utf8"), "original\n");
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

// R13 exercises real RPC delivery, registered Pi consumers and UTF-16 text bounds.
const r13ConsumerArgs: Array<Parameters<typeof toolCall>[1]> = [{ action: "diagnostics", file: "file.ts" }, { action: "diagnostics", file: "*" }, { action: "code_actions", file: "file.ts", line: 1, apply: false }, { action: "hover", file: "file.ts", line: 1 }];
for (const envelope of ["conflict-false", "conflict-zero", "conflict-null", "conflict-valid", "error-false", "error-zero", "error-null", "error-string", "error-missing-code", "error-missing-message", "error-fractional-code", "error-string-code", "missing", "error-valid"]) {
  test(`R13 malformed/conflicting RPC envelope never confirms clean through actual consumers (${envelope})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n");
      const harness = await semanticTsPeer(f.dir, "r13", { body: [], envelope }); runner = harness.runner;
      for (const args of r13ConsumerArgs) {
        const result = await toolCall("lsp", args, harness.tools); assert.equal(result.isError, true);
        assert.match(JSON.stringify(result), envelope === "error-valid" ? /fixture r13 valid error/ : /Invalid LSP/);
        assert.doesNotMatch(JSON.stringify(result), /file is clean|No diagnostics across open files/);
      }
      assert.equal(existsSync(join(f.dir, "code-action-context.json")), false);
      assert.equal(await fs.readFile(file, "utf8"), "x\n");
      const clients = await harness.pool.listSettledClients(); assert.equal(clients.length, 1);
      const client = clients[0].client;
      assert.equal(client.hasDiagnosticsFor(pathToFileURL(file).href), false);
      assert.equal(await client.request("fixture/resultNull", {}, 1000), null, "Rejected envelopes must not leak or replay pending requests");
      assert.equal(records(join(f.dir, "rpc-controls.jsonl")).length, 1);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

const r13Positions = [
  { name: "start-line-outside", text: "x\n", start: { line: 99, offset: 1 }, end: { line: 99, offset: 2 }, valid: false },
  { name: "end-line-outside", text: "x\n", start: { line: 1, offset: 1 }, end: { line: 99, offset: 1 }, valid: false },
  { name: "start-offset-outside", text: "x\n", start: { line: 1, offset: 99 }, end: { line: 1, offset: 100 }, valid: false },
  { name: "end-offset-outside", text: "x\n", start: { line: 1, offset: 1 }, end: { line: 1, offset: 99 }, valid: false },
  { name: "final-empty-offset-outside", text: "x\n", start: { line: 2, offset: 1 }, end: { line: 2, offset: 2 }, valid: false },
  { name: "offset-crosses-next-line", text: "x\nz", start: { line: 1, offset: 3 }, end: { line: 2, offset: 1 }, valid: false },
  { name: "surrogate-pair-outside", text: "😀", start: { line: 1, offset: 1 }, end: { line: 1, offset: 4 }, valid: false },
  { name: "surrogate-pair-UTF16", text: "😀x", start: { line: 1, offset: 1 }, end: { line: 1, offset: 3 }, valid: true },
  { name: "surrogate-interior-UTF16", text: "😀", start: { line: 1, offset: 2 }, end: { line: 1, offset: 3 }, valid: true },
  { name: "zero-width-EOL", text: "x\nz", start: { line: 1, offset: 2 }, end: { line: 1, offset: 2 }, valid: true },
  { name: "zero-width-EOF", text: "😀x", start: { line: 1, offset: 4 }, end: { line: 1, offset: 4 }, valid: true },
  { name: "final-empty-line", text: "x\n", start: { line: 2, offset: 1 }, end: { line: 2, offset: 1 }, valid: true },
  { name: "CRLF-second-line-EOF", text: "x\r\ny", start: { line: 2, offset: 1 }, end: { line: 2, offset: 2 }, valid: true },
  { name: "CRLF-interior-code-unit", text: "x\r\ny", start: { line: 1, offset: 2 }, end: { line: 1, offset: 3 }, valid: true },
  { name: "CRLF-final-empty-line", text: "x\r\n", start: { line: 2, offset: 1 }, end: { line: 2, offset: 1 }, valid: true },
  { name: "cached-trailing-CRLF-EOF", text: "x\r\n", start: { line: 1, offset: 4 }, end: { line: 1, offset: 4 }, valid: true },
  { name: "CR-LF-unicode-separators", text: "a\rb\nc\u2028d\u2029", start: { line: 2, offset: 1 }, end: { line: 5, offset: 1 }, valid: true },
  { name: "empty-file-EOF", text: "", start: { line: 1, offset: 1 }, end: { line: 1, offset: 1 }, valid: true },
];
for (const { name, text, start, end, valid } of r13Positions) {
  test(`R13 completed diagnostic UTF-16 endpoints match captured text through actual consumers (${name})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, text);
      const harness = await semanticTsPeer(f.dir, "r13", { body: [{ start, end, text: "fixture r13 diagnostic", code: 2322, category: "error" }], envelope: "result" }); runner = harness.runner;
      for (const args of r13ConsumerArgs) {
        const result = await toolCall("lsp", args, harness.tools); assert.equal(result.isError, !valid);
        if (!valid) assert.match(JSON.stringify(result), /Invalid TypeScript diagnostic position/);
        else if (args.action === "diagnostics") assert.match(JSON.stringify(result), /2322/);
        assert.doesNotMatch(JSON.stringify(result), /file is clean|No diagnostics across open files/);
      }
      if (valid) {
        const context: unknown = JSON.parse(await fs.readFile(join(f.dir, "code-action-context.json"), "utf8")); assert.ok(lifecycle.isRecord(context));
        assert.deepEqual(context.diagnostics, [{ range: { start: { line: start.line - 1, character: start.offset - 1 }, end: { line: end.line - 1, character: end.offset - 1 } }, message: "fixture r13 diagnostic", code: 2322, severity: 1, source: "typescript" }]);
      } else assert.equal(existsSync(join(f.dir, "code-action-context.json")), false);
      assert.equal(await fs.readFile(file, "utf8"), text);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

test("R13 valid RPC error preserves integer code/message and result:null controls settle once", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const harness = await semanticTsPeer(f.dir, "clean"); runner = harness.runner;
    const client = await harness.pool.getClient({ bin: join(f.dir, "complete-semantics-peer"), args: [], name: "ts-ls", languageId: "typescript" }, f.dir);
    for (const method of ["fixture/validError", "fixture/emptyMessage"]) {
      await assert.rejects(client.request(method, {}, 1000), error => {
        assert.ok(error instanceof Error && "code" in error); assert.equal(error.code, -32603);
        assert.equal(error.message, "LSP " + method + ": " + (method === "fixture/emptyMessage" ? "" : "fixture r13 valid error")); return true;
      });
    }
    assert.equal(await client.request("fixture/resultNull", {}, 1000), null);
    assert.equal(records(join(f.dir, "rpc-controls.jsonl")).length, 3);
    await runner.emit({ type: "session_shutdown", reason: "quit" });
    assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

const r14Consumers = [
  { action: "hover", shape: "edit", apply: false }, { action: "hover", shape: "empty", apply: false },
  { action: "code_actions", shape: "empty", apply: false }, { action: "code_actions", shape: "edit", apply: false },
  { action: "code_actions", shape: "edit", apply: true }, { action: "code_actions", shape: "command", apply: true },
  { action: "code_actions", shape: "deferred", apply: true },
] satisfies Array<{ action: "hover" | "code_actions"; shape: string; apply: boolean }>;
async function r14Invalidate(harness: Awaited<ReturnType<typeof semanticTsPeer>>, client: InstanceType<typeof lsp.LspClient>, file: string, target: string, newer: boolean) {
  if (target === "document") await fs.writeFile(file, "new text\n");
  harness.pool.invalidate(pathToFileURL(target === "document" ? file : join(dirname(file), "dependency.ts")).href);
  const uri = pathToFileURL(file).href; assert.equal(client.hasDiagnosticsFor(uri), false);
  if (newer) {
    await client.ensureOpen(file, "typescript"); await client.refreshTypeScriptDiagnostics(uri, 1000);
    assert.equal(client.hasDiagnosticsFor(uri), true, "A newer certification must not validate the older consumer reply");
  }
}
async function r14Release(dir: string) {
  for (const marker of ["consumer", "resolve", "block"]) await fs.writeFile(join(dir, "release-" + marker), "");
}
for (const consumer of r14Consumers) for (const target of ["document", "dependency"]) for (const newer of [false, true]) {
  test(`R14 exact receipt rejects held ${consumer.action}/${consumer.shape}/apply=${consumer.apply} after ${target} invalidation (newer=${newer})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined; let call: ReturnType<typeof toolCall> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n");
      const harness = await semanticTsPeer(f.dir, "r14-consumer-" + consumer.shape); runner = harness.runner;
      call = toolCall("lsp", { action: consumer.action, file: "file.ts", line: 1, apply: consumer.apply, query: "fixture", timeout: 2 }, harness.tools);
      await waitFor(() => existsSync(join(f.dir, "consumer-held")));
      const clients = await harness.pool.listSettledClients(); assert.equal(clients.length, 1); const client = clients[0].client;
      assert.equal(client.hasDiagnosticsFor(pathToFileURL(file).href), true);
      await r14Invalidate(harness, client, file, target, newer); await r14Release(f.dir);
      const result = await call; assert.equal(result.isError, true); assert.match(JSON.stringify(result), /receipt expired|unconfirmed/);
      assert.equal(await fs.readFile(file, "utf8"), target === "document" ? "new text\n" : "x\n");
      assert.equal(existsSync(join(f.dir, "resolve-dispatched")), false); assert.equal(records(join(f.dir, "command-dispatches.jsonl")).length, 0);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1);
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { await r14Release(f.dir); if (call) await call; await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}
for (const target of ["document", "dependency"]) for (const newer of [false, true]) {
  test(`R14 deferred resolve cannot use expired receipt after ${target} invalidation (newer=${newer})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined; let call: ReturnType<typeof toolCall> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n"); const harness = await semanticTsPeer(f.dir, "r14-resolve-deferred"); runner = harness.runner;
      call = toolCall("lsp", { action: "code_actions", file: "file.ts", line: 1, apply: true, query: "fixture" }, harness.tools);
      await waitFor(() => existsSync(join(f.dir, "resolve-held")));
      const clients = await harness.pool.listSettledClients(); assert.equal(clients.length, 1);
      await r14Invalidate(harness, clients[0].client, file, target, newer); await r14Release(f.dir);
      const result = await call; assert.equal(result.isError, true); assert.match(JSON.stringify(result), /receipt expired|unconfirmed/);
      assert.equal(await fs.readFile(file, "utf8"), target === "document" ? "new text\n" : "x\n");
      assert.equal(records(join(f.dir, "command-dispatches.jsonl")).length, 0);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { await r14Release(f.dir); if (call) await call; await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}
for (const target of ["document", "dependency"]) {
  test(`R14 preparatory file read cannot cross expired first-effect receipt (${target})`, async () => {
    const f = await fixture(), originalRead = fs.readFile; let runner: InstanceType<typeof ExtensionRunner> | undefined, release = () => { }, call: ReturnType<typeof toolCall> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n"); const harness = await semanticTsPeer(f.dir, "r14-first-effect-edit"); runner = harness.runner;
      let held = false; const gate = new Promise<void>(resolve => { release = resolve; });
      Object.defineProperty(fs, "readFile", { value: async (...args: Parameters<typeof fs.readFile>) => {
        if (args[0] === file && existsSync(join(f.dir, "code-action-context.json"))) { held = true; await gate; }
        return originalRead(...args);
      } }); syncBuiltinESMExports();
      call = toolCall("lsp", { action: "code_actions", file: "file.ts", line: 1, apply: true, query: "fixture" }, harness.tools);
      await waitFor(() => held); const clients = await harness.pool.listSettledClients(); assert.equal(clients.length, 1);
      await r14Invalidate(harness, clients[0].client, file, target, false); release();
      const result = await call; assert.equal(result.isError, true); assert.match(JSON.stringify(result), /receipt expired|unconfirmed/);
      assert.equal(await originalRead(file, "utf8"), target === "document" ? "new text\n" : "x\n");
      assert.equal(records(join(f.dir, "command-dispatches.jsonl")).length, 0);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { release(); Object.defineProperty(fs, "readFile", { value: originalRead }); syncBuiltinESMExports(); await r14Release(f.dir); if (call) await call; await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
  test(`R14 queued initial command cannot cross expired first-dispatch receipt (${target})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined, call: ReturnType<typeof toolCall> | undefined, block: Promise<unknown> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n"); const harness = await semanticTsPeer(f.dir, "r14-first-effect-command"); runner = harness.runner;
      assert.equal((await toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools)).isError, false);
      const clients = await harness.pool.listSettledClients(); assert.equal(clients.length, 1); const client = clients[0].client;
      block = client.runAuthorizedExecuteCommand({ command: "r14-block" }, 2000, harness.pool.context(f.dir));
      await waitFor(() => existsSync(join(f.dir, "block-held")));
      let queued = false; const original = client.runAuthorizedExecuteCommand.bind(client);
      client.runAuthorizedExecuteCommand = (...args: Parameters<typeof original>) => { if (lifecycle.isRecord(args[0]) && args[0].command === "r14-follow") queued = true; return original(...args); };
      call = toolCall("lsp", { action: "code_actions", file: "file.ts", line: 1, apply: true, query: "fixture" }, harness.tools);
      await waitFor(() => queued); await r14Invalidate(harness, client, file, target, false); await r14Release(f.dir); await block;
      const result = await call; assert.equal(result.isError, true); assert.match(JSON.stringify(result), /receipt expired|unconfirmed/);
      assert.deepEqual(records(join(f.dir, "command-dispatches.jsonl")).map(row => row.command), ["r14-block"]);
      assert.equal(await fs.readFile(file, "utf8"), target === "document" ? "new text\n" : "x\n");
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { await r14Release(f.dir); if (block) await block; if (call) await call; await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}
for (const consumer of r14Consumers) {
  test(`R14 same-document same-revision refresh preserves held ${consumer.action}/${consumer.shape}/apply=${consumer.apply}`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined, call: ReturnType<typeof toolCall> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n"); const harness = await semanticTsPeer(f.dir, "r14-consumer-" + consumer.shape); runner = harness.runner;
      call = toolCall("lsp", { action: consumer.action, file: "file.ts", line: 1, apply: consumer.apply, query: "fixture" }, harness.tools);
      await waitFor(() => existsSync(join(f.dir, "consumer-held")));
      const clients = await harness.pool.listSettledClients(); assert.equal(clients.length, 1);
      await clients[0].client.refreshTypeScriptDiagnostics(pathToFileURL(file).href, 1000); await r14Release(f.dir);
      const result = await call; assert.equal(result.isError, false);
      assert.equal(await fs.readFile(file, "utf8"), consumer.apply ? "FOLLOW\n" : "x\n");
      if (consumer.apply) { assert.ok(existsSync(join(f.dir, "ack-901"))); assert.deepEqual(records(join(f.dir, "command-dispatches.jsonl")).map(row => row.command), ["r14-follow"]); }
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1);
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { await r14Release(f.dir); if (call) await call; await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}
for (const phase of ["hover", "code_actions", "resolve"]) {
  test(`R14 held ${phase} cancellation settles promptly without effects or pending groups`, async () => {
    const f = await fixture(), abort = new AbortController(); let runner: InstanceType<typeof ExtensionRunner> | undefined, call: ReturnType<typeof toolCall> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n"); const harness = await semanticTsPeer(f.dir, phase === "resolve" ? "r14-resolve-deferred" : "r14-consumer-edit"); runner = harness.runner;
      call = toolCall("lsp", { action: phase === "hover" ? "hover" : "code_actions", file: "file.ts", line: 1, apply: phase !== "hover", query: "fixture" }, harness.tools, abort.signal);
      await waitFor(() => existsSync(join(f.dir, phase === "resolve" ? "resolve-held" : "consumer-held")));
      const start = Date.now(); abort.abort(); const result = await call; assert.equal(result.isError, true); assert.match(JSON.stringify(result), /cancel/i); assert.ok(Date.now() - start < 500);
      assert.equal(await fs.readFile(file, "utf8"), "x\n"); assert.equal(records(join(f.dir, "command-dispatches.jsonl")).length, 0);
      await r14Release(f.dir); await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
    } finally { abort.abort(); await r14Release(f.dir); if (call) await call; await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

for (const shape of ["deferred", "command"]) for (const resolveProvider of [true, false]) {
  test(`R15 resolve failure preserves original error and forbids fallback (${shape}, provider=${resolveProvider})`, async () => {
    const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      const file = join(f.dir, "file.ts"); await fs.writeFile(file, "x\n");
      const harness = await semanticTsPeer(f.dir, (resolveProvider ? "r15-" : "r15-no-resolve-") + shape); runner = harness.runner;
      const result = await toolCall("lsp", { action: "code_actions", file: "file.ts", line: 1, apply: true, query: "fixture", timeout: 1 }, harness.tools);
      assert.equal(result.isError, resolveProvider);
      if (resolveProvider) {
        assert.match(JSON.stringify(result), /LSP codeAction\/resolve: offline resolve failed/);
        assert.doesNotMatch(JSON.stringify(result), /produced no edits|Applied \"fixture action/);
        assert.equal(existsSync(join(f.dir, "resolve-dispatched")), true);
        assert.equal(records(join(f.dir, "command-dispatches.jsonl")).length, 0);
        assert.equal(await fs.readFile(file, "utf8"), "x\n");
      } else {
        assert.equal(existsSync(join(f.dir, "resolve-dispatched")), false, "Without advertised resolve support there is no RPC or error fallback");
        assert.deepEqual(records(join(f.dir, "command-dispatches.jsonl")).map(row => row.command), shape === "command" ? ["r15-follow"] : []);
        assert.equal(await fs.readFile(file, "utf8"), shape === "command" ? "FOLLOW\n" : "x\n");
      }
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1);
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
      assert.equal(records(f.events).find(row => row.kind === "shutdown_summary")?.ok, true);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
  });
}

const assistantMessage: AssistantMessage = {
  role: "assistant", content: [], api: "openai-completions", provider: "fixture", model: "fixture",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "toolUse", timestamp: 0,
};
function isJsonValue(value: unknown): value is import("@earendil-works/pi-ai").JsonValue {
  return value === null || typeof value === "string" || typeof value === "boolean"
    || (typeof value === "number" && Number.isFinite(value))
    || (Array.isArray(value) && value.every(isJsonValue))
    || (lifecycle.isRecord(value) && Object.values(value).every(isJsonValue));
}
function isJsonObject(value: unknown): value is Parameters<typeof runToolCall>[0]["arguments"] {
  return lifecycle.isRecord(value) && Object.values(value).every(isJsonValue);
}
async function toolCall(name: string, args: Parameters<typeof runToolCall>[0]["arguments"], tools: Parameters<typeof runToolCall>[1]["tools"], signal?: AbortSignal) {
  return runToolCall({ type: "toolCall", id: "t029-call", name, arguments: args }, {
    tools, assistantMessage, context: { messages: [], tools: [...tools] }, signal,
  });
}

test("cancelled command A is quarantined before fresh B authority, and late A cannot overwrite B", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool();
  try {
    const spec = await fakeLsp(f.dir), path = join(f.dir, "file.ts"); await fs.writeFile(path, "x\n");
    const uri = pathToFileURL(path).href, first = await pool.getClient(spec, f.dir);
    const controller = new AbortController();
    const command = first.runAuthorizedExecuteCommand({ command: "A", arguments: [uri] }, 1000, pool.context(f.dir, controller.signal));
    const rejected = assert.rejects(command, { name: "AbortError" });
    await waitFor(() => existsSync(join(f.dir, "dispatched-A"))); controller.abort(); await rejected;
    assert.equal(first.applyQuarantined, true);
    const second = await pool.getClient(spec, f.dir); assert.notEqual(first, second);
    await second.runAuthorizedExecuteCommand({ command: "B", arguments: [uri] }, 1000, pool.context(f.dir));
    await sleep(100); assert.equal(existsSync(join(f.dir, "late-sent-A")), true); assert.equal(await fs.readFile(path, "utf8"), "B\n");
    await assert.rejects(first.runAuthorizedExecuteCommand({ command: "B", arguments: [uri] }, 1000, pool.context(f.dir)), /retired/);
    assert.equal(records(f.events).filter(record => record.kind === "group_birth").length, 2);
  } finally { await pool.shutdown("quit", "fixture"); await f.close(); }
});

test("queued B abort cannot release live C before running A confirms or move A effects to C", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool(), runs: Promise<unknown>[] = [];
  try {
    const spec = await fakeLsp(f.dir), path = join(f.dir, "file.ts"); await fs.writeFile(path, "x\n");
    const client = await pool.getClient(spec, f.dir), uri = pathToFileURL(path).href;
    const aCtx = pool.context(f.dir), bController = new AbortController(), bCtx = pool.context(f.dir, bController.signal), cCtx = pool.context(f.dir);
    const a = client.runAuthorizedExecuteCommand({ command: "queue-A", arguments: [uri] }, 3000, aCtx); a.catch(() => {}); runs.push(a);
    await waitFor(() => existsSync(join(f.dir, "dispatched-queue-A")));
    const b = client.runAuthorizedExecuteCommand({ command: "queue-B", arguments: [uri] }, 3000, bCtx); b.catch(() => {}); runs.push(b);
    const rejected = assert.rejects(b, { name: "AbortError" }); bController.abort(); await rejected;
    const c = client.runAuthorizedExecuteCommand({ command: "C", arguments: [uri] }, 3000, cCtx); c.catch(() => {}); runs.push(c);
    await sleep(40);
    assert.equal(existsSync(join(f.dir, "dispatched-C")), false, "C must remain queued behind unconfirmed A");
    assert.equal(existsSync(join(f.dir, "dispatched-queue-B")), false);
    await fs.writeFile(join(f.dir, "send-A-edit"), "");
    await waitFor(() => existsSync(join(f.dir, "queue-a-ack")));
    assert.equal(await fs.readFile(path, "utf8"), "A\n");
    assert.equal(aCtx.ledger.hasIssuedEffects, true); assert.equal(cCtx.ledger.hasIssuedEffects, false); assert.equal(bCtx.ledger.hasIssuedEffects, false);
    assert.equal(existsSync(join(f.dir, "dispatched-C")), false);
    await fs.writeFile(join(f.dir, "release-A"), "");
    await a; await c;
    assert.equal(await fs.readFile(path, "utf8"), "C\n"); assert.equal(cCtx.ledger.hasIssuedEffects, true);
    assert.equal(records(f.events).filter(record => record.kind === "group_birth").length, 1);
  } finally {
    await fs.writeFile(join(f.dir, "send-A-edit"), ""); await fs.writeFile(join(f.dir, "release-A"), "");
    await pool.shutdown("quit", "fixture"); await Promise.allSettled(runs); await f.close();
  }
});

test("actual diagnostics consumer cancels its publish wait promptly without clean evidence", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const spec = await fakeLsp(f.dir), path = join(f.dir, "file.ts"); await fs.writeFile(path, "x");
    await enableCompletedTsPeer(spec.bin);
    const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8");
    const source = raw.replace("___TS_LSP___", spec.bin).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts")));
    const modulePath = join(f.dir, "lsp.ts"); await fs.writeFile(modulePath, source);
    const loaded = await fixtureImport(pathToFileURL(modulePath).href), harness = await runnerFor(loaded.default, f.dir); runner = harness.runner;
    const controller = new AbortController(), call = toolCall("lsp", { action: "diagnostics", file: "file.ts" }, harness.tools, controller.signal);
    await waitFor(() => existsSync(join(f.dir, "didopen-seen")));
    const started = performance.now(); controller.abort(); const result = await call;
    assert.equal(result.isError, true); assert.doesNotMatch(JSON.stringify(result), /file is clean/); assert.match(JSON.stringify(result), /cancel|Abort/i);
    assert.ok(performance.now() - started < 1000, "fixture cancellation must not retain the 2500ms diagnostics timer");
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

test("actual workspace-symbol consumer preserves cancellation and unsupported distinction", async () => {
  const f = await fixture(); let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const spec = await fakeLsp(f.dir), path = join(f.dir, "file.ts"); await fs.writeFile(path, "x");
    const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8");
    const source = raw.replace("___TS_LSP___", spec.bin).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts")));
    const modulePath = join(f.dir, "lsp.ts"); await fs.writeFile(modulePath, source);
    const loaded = await fixtureImport(pathToFileURL(modulePath).href), harness = await runnerFor(loaded.default, f.dir); runner = harness.runner;
    assert.equal((await toolCall("lsp", { action: "capabilities", file: "file.ts" }, harness.tools)).isError, false);
    const unsupported = await toolCall("lsp", { action: "symbols", file: "*", query: "unsupported" }, harness.tools);
    assert.equal(unsupported.isError, false); assert.match(JSON.stringify(unsupported), /No workspace symbols/);
    await fs.rm(join(f.dir, "symbols-seen"));
    const controller = new AbortController(), call = toolCall("lsp", { action: "symbols", file: "*", query: "Foo" }, harness.tools, controller.signal);
    await waitFor(() => existsSync(join(f.dir, "symbols-seen")));
    const started = performance.now(); controller.abort(); const result = await call;
    assert.equal(result.isError, true); assert.doesNotMatch(JSON.stringify(result), /No workspace symbols match/); assert.match(JSON.stringify(result), /cancel|Abort/i);
    assert.ok(performance.now() - started < 1000);
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

test("URI validation precedes all effects; abort after preparatory read admits no write", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool();
  const original = fs.readFile;
  try {
    const path = join(f.dir, "file.ts"); await fs.writeFile(path, "x");
    const ctx = pool.context(f.dir);
    await assert.rejects(lsp.applyWorkspaceEdit({ documentChanges: [{ kind: "create", uri: pathToFileURL(join(f.dir, "new")).href }, { kind: "create", uri: "https://example.invalid/file" }] }, ctx), /file:/);
    assert.equal(ctx.ledger.hasIssuedEffects, false); assert.equal(existsSync(join(f.dir, "new")), false);
    const controller = new AbortController();
    let release = () => { }, entered = false;
    const gate = new Promise<void>(resolve => { release = resolve; });
    Object.defineProperty(fs, "readFile", { value: async (...args: Parameters<typeof fs.readFile>) => {
      if (args[0] === path) { entered = true; await gate; }
      return original(...args);
    } }); syncBuiltinESMExports();
    const abortCtx = pool.context(f.dir, controller.signal);
    const apply = lsp.applyWorkspaceEdit({ changes: { [pathToFileURL(path).href]: [{ range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } }, newText: "B" }] } }, abortCtx);
    const rejected = assert.rejects(apply, { name: "AbortError" });
    await waitFor(() => entered); controller.abort(); release(); await rejected;
    assert.equal(abortCtx.ledger.hasIssuedEffects, false);
    assert.equal(await original(path, "utf8"), "x");
  } finally { Object.defineProperty(fs, "readFile", { value: original }); syncBuiltinESMExports(); await pool.shutdown("quit", "fixture"); await f.close(); }
});

test("issued mkdir remains possibly modified on abort, and touched documents are invalidated", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool(), original = fs.mkdir;
  try {
    const parent = join(f.dir, "made"), path = join(parent, "file.ts"), controller = new AbortController();
    Object.defineProperty(fs, "mkdir", { value: async (...args: Parameters<typeof fs.mkdir>) => {
      const result = await original(...args); if (args[0] === parent) controller.abort(); return result;
    } }); syncBuiltinESMExports();
    const touched: string[] = [], ctx = pool.context(f.dir, controller.signal); ctx.invalidate = uri => { touched.push(uri); };
    await assert.rejects(lsp.applyWorkspaceEdit({ documentChanges: [{ kind: "create", uri: pathToFileURL(path).href }] }, ctx), { name: "AbortError" });
    assert.equal(existsSync(parent), true); assert.equal(existsSync(path), false);
    assert.equal(ctx.ledger.hasIssuedEffects, true); assert.deepEqual(ctx.ledger.completed, []);
    assert.ok(ctx.ledger.uncertainPaths.has(parent)); assert.ok(touched.includes(pathToFileURL(parent).href));
  } finally { Object.defineProperty(fs, "mkdir", { value: original }); syncBuiltinESMExports(); await pool.shutdown("quit", "fixture"); await f.close(); }
});

test("actual LSP native consumer preserves partial ENOSPC effects and returns isError", async () => {
  const f = await fixture(), original = fs.writeFile;
  let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const spec = await fakeLsp(f.dir), path = join(f.dir, "file.ts"); await fs.writeFile(path, "x\n");
    const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8");
    const rendered = raw.replace("___TS_LSP___", spec.bin).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts")));
    const modulePath = join(f.dir, "lsp.ts"); await fs.writeFile(modulePath, rendered);
    const loaded = await fixtureImport(pathToFileURL(modulePath).href);
    assert.equal(typeof loaded.default, "function");
    const harness = await runnerFor(loaded.default, f.dir); runner = harness.runner;
    Object.defineProperty(fs, "writeFile", { value: async (...args: Parameters<typeof fs.writeFile>) => {
      if (args[0] === path) { await original(path, "partial"); throw Object.assign(new Error("fixture ENOSPC"), { code: "ENOSPC" }); }
      return original(...args);
    } }); syncBuiltinESMExports();
    const outcome = await toolCall("lsp", { action: "rename", file: "file.ts", line: 1, new_name: "B", apply: true }, harness.tools);
    assert.equal(outcome.isError, true); assert.match(JSON.stringify(outcome.result), /ENOSPC/);
    assert.equal(await fs.readFile(path, "utf8"), "partial");
    assert.ok(lifecycle.isRecord(outcome.result.details));
    assert.equal(outcome.result.details.hasIssuedEffects, true);
    assert.deepEqual(outcome.result.details.completed, []);
    assert.deepEqual(outcome.result.details.possiblyModified, [path]);
    const command = await toolCall("lsp", { action: "request", file: "file.ts", query: "workspace/executeCommand", apply: true,
      payload: JSON.stringify({ command: "B", arguments: [pathToFileURL(path).href] }) }, harness.tools);
    assert.equal(command.isError, true); assert.match(JSON.stringify(command.result), /ENOSPC/);
    assert.ok(lifecycle.isRecord(command.result.details)); assert.equal(command.result.details.hasIssuedEffects, true);
  } finally { Object.defineProperty(fs, "writeFile", { value: original }); syncBuiltinESMExports(); await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

test("independent-stdio SIGTERM-ignoring grandchild is killed after early leader exit", async () => {
  const f = await fixture();
  let group: ReturnType<typeof lifecycle.spawnManagedGroup> | undefined;
  try {
    const grandchild = `process.on('SIGTERM', () => {}); require('node:fs').writeFileSync(${JSON.stringify(join(f.dir, "grandchild"))}, String(process.pid)); setInterval(() => {}, 1000);`;
    const leader = `const child = require('node:child_process').spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(grandchild)}], {stdio: 'ignore'}); child.unref(); setTimeout(() => process.exit(0), 100);`;
    group = lifecycle.spawnManagedGroup("fixture", "early-leader", process.execPath, ["-e", leader]);
    group.child.stdout.resume(); group.child.stderr.resume();
    await waitFor(() => existsSync(join(f.dir, "grandchild")));
    await new Promise<void>(resolve => group?.child.once("close", () => resolve()));
    const outcome = await group.shutdown(); assert.equal(outcome.ok, true, JSON.stringify(outcome));
    const pgid = outcome.pgid; assert.ok(pgid); assert.throws(() => process.kill(-pgid, 0), /ESRCH/);
    assert.equal(await group.shutdown(), outcome);
  } finally { if (group) await group.shutdown(); await f.close(); }
});

test("failed-init eviction retains actual cleanup failure in the shutdown summary", async () => {
  const f = await fixture(), pool = new lsp.LspSessionPool(), original = process.kill;
  let ownedPid: number | undefined;
  try {
    const spec = await fakeLsp(f.dir, true);
    Object.defineProperty(process, "kill", { value: (pid: number, signal?: Parameters<typeof process.kill>[1]) => {
      if (ownedPid !== undefined && pid === -ownedPid && signal !== 0) throw Object.assign(new Error("fixture denied group signal"), { code: "EPERM" });
      return original(pid, signal);
    } });
    const init = pool.getClient(spec, f.dir);
    const rejected = assert.rejects(init, /fixture init failed/);
    await waitFor(() => records(f.events).some(record => record.kind === "group_birth"));
    const birth = records(f.events).find(record => record.kind === "group_birth"); assert.ok(birth && typeof birth.childPid === "number"); ownedPid = birth.childPid;
    await rejected; assert.equal(pool.entries.size, 0);
    await assert.rejects(pool.shutdown("quit", "fixture"), /cleanup failed/);
    const summary = records(f.events).find(record => record.kind === "shutdown_summary"); assert.ok(summary);
    assert.equal(summary.ok, false); assert.ok(Array.isArray(summary.failedGroups)); assert.equal(summary.failedGroups.length, 1);
    assert.equal(existsSync(join(f.dir, "state/pi/lifecycle-errors.jsonl")), true);
  } finally { Object.defineProperty(process, "kill", { value: original }); if (ownedPid) { try { original(-ownedPid, "SIGKILL"); } catch { } } await sleep(50); await f.close(); }
});

test("actual reload-all consumer reports denied process-group cleanup", async () => {
  const f = await fixture(), original = process.kill;
  let runner: InstanceType<typeof ExtensionRunner> | undefined, ownedPid: number | undefined;
  try {
    const spec = await fakeLsp(f.dir, false, true), file = join(f.dir, "file.ts"); await fs.writeFile(file, "x");
    const raw = await fs.readFile(join(sourceRoot, "lsp-extension.ts"), "utf8");
    const source = raw.replace("___TS_LSP___", spec.bin).replace('"./pi-extensions/lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts")));
    const path = join(f.dir, "lsp.ts"); await fs.writeFile(path, source);
    const loaded = await fixtureImport(pathToFileURL(path).href);
    const harness = await runnerFor(loaded.default, f.dir); runner = harness.runner;
    assert.equal((await toolCall("lsp", { action: "capabilities", file: "file.ts" }, harness.tools)).isError, false);
    const birth = records(f.events).find(record => record.kind === "group_birth"); assert.ok(birth && typeof birth.childPid === "number"); ownedPid = birth.childPid;
    Object.defineProperty(process, "kill", { value: (pid: number, signal?: Parameters<typeof process.kill>[1]) => {
      if (ownedPid !== undefined && pid === -ownedPid && signal !== 0) throw Object.assign(new Error("fixture denied group signal"), { code: "EPERM" });
      return original(pid, signal);
    } });
    const outcome = await toolCall("lsp", { action: "reload", file: "*" }, harness.tools);
    assert.equal(outcome.isError, true); assert.match(JSON.stringify(outcome.result), /denied group signal/);
  } finally {
    Object.defineProperty(process, "kill", { value: original });
    if (ownedPid) { try { original(-ownedPid, "SIGKILL"); } catch {} }
    await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close();
  }
});

test("held apply drain runs concurrently with group cleanup and reports unsettledApplies", async () => {
  const f = await fixture();
  try {
    const group = lifecycle.spawnManagedGroup("fixture", "held-drain", process.execPath, ["-e", "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)"]);
    group.child.stdout.resume(); group.child.stderr.resume();
    await sleep(50);
    const tracker = new lifecycle.SessionCleanupTracker("fixture");
    const held = new Promise<void>(() => { });
    const start = performance.now();
    await assert.rejects(tracker.runSessionShutdown({ reason: "quit", sessionId: "fixture", activeCleanups: [group.shutdown()], drainPromises: [held], drainTimeoutMs: 2000 }), /1 unsettled applies/);
    assert.ok(performance.now() - start < 2600, "cleanup and drain must overlap");
    const outcome = await group.shutdown(); assert.equal(outcome.ok, true);
    const summary = records(f.events).find(record => record.kind === "shutdown_summary"); assert.ok(summary); assert.equal(summary.unsettledApplies, 1);
  } finally { await f.close(); }
});

test("durable failure survives real ExtensionRunner.emit and a stopped-TUI quit process", async () => {
  const f = await fixture();
  try {
    const tracker = new lifecycle.SessionCleanupTracker("fixture");
    let release = () => { }; const held = new Promise<void>(resolve => { release = resolve; });
    const harness = await runnerFor(pi => { pi.on("session_shutdown", event => tracker.runSessionShutdown({ reason: event.reason, sessionId: "fixture", activeCleanups: [], drainPromises: [held], drainTimeoutMs: 5 }).then(() => { })); }, f.dir);
    await harness.runner.emit({ type: "session_shutdown", reason: "quit" }); release();
    assert.equal(records(f.events).find(record => record.kind === "shutdown_summary")?.ok, false);
    const child = join(f.dir, "quit.ts");
    const helper = pathToFileURL(join(sourceRoot, "pi-extensions/lib/lifecycle.ts")).href;
    const tuiModule = pathToFileURL(join(modules, "@earendil-works/pi-tui/dist/tui-main-screen.js")).href;
    await fs.writeFile(child, `import { SessionCleanupTracker } from ${JSON.stringify(helper)}; import { TuiMainScreen } from ${JSON.stringify(tuiModule)};
let stopped = false;
const terminal = { start() {}, stop() { stopped = true; }, async drainInput() {}, write() {}, columns: 80, rows: 24, kittyProtocolActive: false, moveBy() {}, hideCursor() {}, showCursor() {}, clearLine() {}, clearFromCursor() {}, clearScreen() {}, setTitle() {}, setProgress() {}, setProgramStatus() {} };
const tui = new TuiMainScreen(terminal); tui.stop();
try { await new SessionCleanupTracker('quit-fixture').runSessionShutdown({reason:'quit', sessionId:'fixture', activeCleanups:[], drainPromises:[new Promise(() => {})], drainTimeoutMs:5}); } catch {}
if (!stopped) throw new Error('Native TUI did not stop'); process.exit(0);`);
    const result = spawnSync(process.execPath, ["--experimental-strip-types", child], { env: process.env, encoding: "utf8", timeout: 3000 });
    assert.equal(result.status, 0, result.stderr);
    const summaries = records(f.events).filter(record => record.kind === "shutdown_summary"); assert.equal(summaries.length, 2);
    assert.equal(summaries[1].reason, "quit"); assert.equal(summaries[1].ok, false);
    assert.equal(records(join(f.dir, "state/pi/lifecycle-errors.jsonl")).length, 2);
  } finally { await f.close(); }
});

test("unwritable lifecycle logs cannot lose child ownership or reject cleanup", async () => {
  const f = await fixture();
  try {
    process.env.PI_LIFECYCLE_EVENTS_FILE = f.dir;
    const blocking = join(f.dir, "blocking"); await fs.writeFile(blocking, "file"); process.env.XDG_STATE_HOME = blocking;
    const group = lifecycle.spawnManagedGroup("fixture", "unwritable-log", process.execPath, ["-e", "setInterval(() => {}, 1000)"]);
    group.child.stdout.resume(); group.child.stderr.resume();
    const outcome = await group.shutdown(); assert.equal(outcome.ok, true);
    const tracker = new lifecycle.SessionCleanupTracker("fixture"); tracker.trackRetiring(group.shutdown());
    assert.equal((await tracker.runSessionShutdown({ reason: "quit", sessionId: "fixture", activeCleanups: [], drainPromises: [] })).ok, true);
  } finally { await f.close(); }
});

async function browserFixture(dir: string, initFailure = false) {
  const binary = join(dir, "fake-browser-task");
  const schema = { type: "object", properties: { task: { type: "string" }, action: { type: "object" } }, required: ["task", "action"] };
  await fs.writeFile(binary, `#!${fixturePython}
import json, sys, threading
lock = threading.Lock()
def send(frame):
    with lock:
        print(json.dumps(frame), flush=True)
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('method') == 'initialize':
        threading.Timer(.08, lambda msg=msg: send({'id':msg['id'], ${initFailure ? "'error': {'message':'fixture init failed'}" : "'result': {}"}})).start()
    if msg.get('method') == 'tools/list':
        send({'id':msg['id'], 'result': {'tools': [{'name': 'dev_browser', 'inputSchema': json.loads(${JSON.stringify(JSON.stringify(schema))})}]}})
    if msg.get('method') == 'tools/call':
        with open(${JSON.stringify(join(dir, "browser-dispatches"))}, 'a') as out:
            out.write(json.dumps(msg['params']['arguments']) + '\\n')
        send({'id': msg['id'], 'result': {'content': [{'type':'text', 'text':'fixture action'}]}})
`, { mode: 0o700 });
  const nix = await fs.readFile(join(sourceRoot, "pi.nix"), "utf8");
  const template = /browserMcpTemplate = pkgs.writeText "browser-mcp-template.ts" ''\n([\s\S]*?)\n  '';/.exec(nix); assert.ok(template);
  const source = template[1].replace(/__DEV_BROWSER_SCHEMA__/, JSON.stringify(JSON.stringify(schema)))
    .replace(/const BROWSER_TASK = .*;/, "const BROWSER_TASK = " + JSON.stringify(binary) + ";")
    .replace('"./lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts")));
  const path = join(dir, "browser-mcp.ts"); await fs.writeFile(path, source);
  return fixtureImport(pathToFileURL(path).href);
}

test("BrowserMcp readiness belongs to session, while one caller abort leaves the second usable", async () => {
  const f = await fixture();
  let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const browser = await browserFixture(f.dir), harness = await runnerFor(browser.default, f.dir); runner = harness.runner;
    assert.equal(records(f.events).filter(record => record.kind === "group_birth").length, 0);
    const controller = new AbortController();
    const first = toolCall("dev_browser", { task: "first", action: { type: "snapshot" } }, harness.tools, controller.signal);
    const second = toolCall("dev_browser", { task: "second", action: { type: "snapshot" } }, harness.tools);
    await sleep(20); controller.abort();
    assert.equal((await first).isError, true); assert.equal((await second).isError, false);
    const dispatches = (await fs.readFile(join(f.dir, "browser-dispatches"), "utf8")).trim().split("\n").map(line => JSON.parse(line));
    assert.equal(dispatches.length, 1); assert.equal(dispatches[0].task, "second");
    assert.equal(records(f.events).filter(record => record.kind === "group_birth").length, 1);
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); await f.close(); }
});

test("BrowserMcp failed readiness retires the client and retains cleanup for session shutdown", async () => {
  const f = await fixture();
  try {
    const browser = await browserFixture(f.dir, true), harness = await runnerFor(browser.default, f.dir);
    const outcome = await toolCall("dev_browser", { task: "failed", action: { type: "snapshot" } }, harness.tools);
    assert.equal(outcome.isError, true);
    await harness.runner.emit({ type: "session_shutdown", reason: "quit" });
    assert.equal(records(f.events).find(record => record.kind === "group_settled")?.ok, true);
    assert.equal(records(f.events).find(record => record.kind === "shutdown_summary")?.ok, true);
  } finally { await f.close(); }
});

async function currentMcpPeer(dir: string) {
  const binary = join(dir, "current-mcp-peer");
  await fs.writeFile(binary, `#!${fixturePython}
import ast, asyncio, inspect, json, os, re, sys, types, typing
source = os.environ.get('PI_EXTENSION_MCP_NIXOS_SOURCE')
async def fixture_to_thread(function, *args): return function(*args)
namespace = {'Annotated': typing.Annotated, 'Any': typing.Any, 'asyncio': types.SimpleNamespace(to_thread=fixture_to_thread), 'json': json, 're': re, 'MAX_LINE_LIMIT': 2000}
namespace['error'] = lambda msg, code='ERROR': 'Error (' + code + '): ' + str(msg)
namespace['_search_nixos'] = lambda query, kind, limit, channel: 'Fixture package: ' + query + ' channel=' + channel
namespace['_list_channels'] = lambda: 'Fixture channels: unstable, stable'
namespace['_fetch_nixhub_pkg'] = lambda package: (None, [{'version': '1.0', 'commit_hash': 'a' * 40, 'systems': {'x86_64-linux': {'attr_paths': [package]}}}])
if source:
    tree = ast.parse(open(source).read())
    tools = [node for node in tree.body if isinstance(node, ast.AsyncFunctionDef) and any(isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute) and d.func.attr == 'tool' for d in node.decorator_list)]
    for node in tools: node.decorator_list = []
    exec(compile(ast.Module(body=tools, type_ignores=[]), source, 'exec'), namespace)
else:
    async def nix(action: str, query: str='', source: str='nixos', type: str='packages', channel: str='unstable', limit: int=20, version: str='latest', system: str=''):
        if not 1 <= limit <= 100: return namespace['error']('Limit must be 1-100')
        if action == 'channels': return namespace['_list_channels']()
        if action == 'search' and query and source == 'nixos': return namespace['_search_nixos'](query, type, limit, channel)
        return namespace['error']('Invalid action, query or source')
    async def nix_versions(package: str, version: str='', limit: int=10):
        if not package or not 1 <= limit <= 50: return namespace['error']('Invalid package or limit')
        return 'Found ' + package + ' version ' + version
    namespace.update(nix=nix, nix_versions=nix_versions)
catalog = {name: value for name, value in namespace.items() if inspect.iscoroutinefunction(value)}
with open(${JSON.stringify(join(dir, "backend-catalog.json"))}, 'w') as out:
    json.dump({name: str(inspect.signature(value)) for name, value in catalog.items()}, out)
def call_tool(call):
    try:
        if call['name'] not in catalog: raise ValueError('Unknown tool: ' + call['name'])
        function = catalog[call['name']]
        bound = inspect.signature(function).bind(**call['arguments']); bound.apply_defaults()
        for name, value in bound.arguments.items():
            annotation = inspect.signature(function).parameters[name].annotation
            expected = typing.get_args(annotation)[0] if typing.get_origin(annotation) is typing.Annotated else annotation
            if not isinstance(value, expected): raise ValueError('Invalid argument type: ' + name)
        text = asyncio.run(function(**bound.arguments))
        result = {'id': 2, 'result': {'isError': False, 'content': [{'type': 'text', 'text': text}]}}
    except Exception as error:
        result = {'id': 2, 'error': {'code': -32602, 'message': str(error)}}
    result['jsonrpc'] = '2.0'
    print(json.dumps(result), flush=True)
for line in sys.stdin:
    frame = json.loads(line)
    if frame.get('method') == 'initialize': print(json.dumps({'jsonrpc':'2.0','id':1,'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture-mcp','version':'1'}}}), flush=True)
    if frame.get('method') == 'tools/call': call_tool(frame['params'])
`, { mode: 0o700 });
  return binary;
}

test("LIVE-2 current nix and nix_versions consumers validate arguments, backend errors and cleanup", async () => {
  const f = await fixture(), previous = process.env.MCP_NIXOS_BIN;
  let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    process.env.MCP_NIXOS_BIN = await currentMcpPeer(f.dir);
    const native = await fixtureImport(pathToFileURL(join(sourceRoot, "pi-extensions/mcp-nixos.ts")).href + "?fixture=" + encodeURIComponent(f.dir));
    const harness = await runnerFor(native.default, f.dir); runner = harness.runner;
    const tool = harness.tools.find(tool => tool.name === "nixos"); assert.ok(tool);
    const schema: unknown = tool.parameters; assert.ok(lifecycle.isRecord(schema) && lifecycle.isRecord(schema.properties) && lifecycle.isRecord(schema.properties.tool));
    if (Array.isArray(schema.properties.tool.enum) && schema.properties.tool.enum.includes("nixos_channels")) {
      const advertised = await toolCall("nixos", { tool: "nixos_channels", arguments: {} }, harness.tools);
      assert.equal(advertised.isError, false, "Advertised tool failed: " + JSON.stringify(advertised));
    }
    const lookup = await toolCall("nixos", { tool: "nix", arguments: { action: "search", query: "hello", channel: "stable" } }, harness.tools);
    assert.equal(lookup.isError, false); assert.match(JSON.stringify(lookup), /Fixture package: hello channel=stable/);
    const versions = await toolCall("nixos", { tool: "nix_versions", arguments: { package: "hello", version: "1.0" } }, harness.tools);
    assert.equal(versions.isError, false, JSON.stringify(versions)); assert.match(JSON.stringify(versions), /Found hello version 1.0/);
    const catalog: unknown = JSON.parse(await fs.readFile(join(f.dir, "backend-catalog.json"), "utf8")); assert.ok(lifecycle.isRecord(catalog));
    assert.deepEqual(schema.properties.tool.enum, Object.keys(catalog).sort());
    const invalidArgs: Parameters<typeof runToolCall>[0]["arguments"][] = [{ action: "search", query: 17 }, {}, { action: "channels", limit: 0 }, { action: "search", query: "hello", source: "unknown-source" }];
    for (const args of invalidArgs) {
      const failed = await toolCall("nixos", { tool: "nix", arguments: args }, harness.tools);
      assert.equal(failed.isError, true, JSON.stringify(failed)); assert.match(JSON.stringify(failed), /Invalid|Error|missing/i);
    }
    assert.equal((await toolCall("nixos", { tool: "nix_versions", arguments: { package: "hello", limit: 0 } }, harness.tools)).isError, true);
    const births = records(f.events).filter(record => record.kind === "group_birth").length;
    assert.equal((await toolCall("nixos", { tool: "nixos_channels" }, harness.tools)).isError, true);
    assert.equal(records(f.events).filter(record => record.kind === "group_birth").length, births, "Legacy names must reject before spawn");
    const executeTool: ExtensionToolContext["executeTool"] = (name, args, options) => {
      assert.ok(isJsonObject(args)); return toolCall(name, args, harness.tools, options?.signal);
    };
    const ctx: ExtensionToolContext = Object.assign(runner.createContext(), { tools: harness.tools, executeTool });
    assert.notEqual((await executeCodemode("r4-success", { code: 'await tools.nixos({tool:"nix",arguments:{action:"channels"}});' }, undefined, undefined, ctx)).isError, true);
    assert.equal((await executeCodemode("r4-error", { code: 'await tools.nixos({tool:"nix",arguments:{action:"channels",limit:0}});' }, undefined, undefined, ctx)).isError, true);
    const completed = records(f.events).filter(record => record.kind === "group_settled");
    assert.equal(completed.length, records(f.events).filter(record => record.kind === "group_birth").length);
    assert.ok(completed.every(record => record.ok === true));
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); if (previous === undefined) delete process.env.MCP_NIXOS_BIN; else process.env.MCP_NIXOS_BIN = previous; await f.close(); }
});

test("actual mcp-nixos runToolCall and codemode consumers distinguish isError from empty success", async () => {
  const f = await fixture(), previous = process.env.MCP_NIXOS_BIN;
  let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const binary = join(f.dir, "fake-mcp-nixos");
    await fs.writeFile(binary, `#!${fixturePython}
import json, sys
for line in sys.stdin:
    frame = json.loads(line)
    if frame.get('method') == 'initialize': print(json.dumps({'jsonrpc':'2.0','id':1,'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture-mcp','version':'1'}}}), flush=True)
    if frame.get('method') == 'tools/call':
        failed = frame['params']['arguments'].get('action') == 'fixture_error'
        print(json.dumps({'jsonrpc':'2.0','id':2, 'result': {'isError':failed, 'content':[{'type':'text','text':'fixture MCP error'}] if failed else []}}), flush=True)
`, { mode: 0o700 }); process.env.MCP_NIXOS_BIN = binary;
    const native = await fixtureImport(pathToFileURL(join(sourceRoot, "pi-extensions/mcp-nixos.ts")).href + "?fixture=" + encodeURIComponent(f.dir)); const harness = await runnerFor(native.default, f.dir); runner = harness.runner;
    const failed = await toolCall("nixos", { tool: "nix", arguments: { action: "fixture_error" } }, harness.tools);
    assert.equal(failed.isError, true); assert.match(JSON.stringify(failed.result), /fixture MCP error/);
    assert.equal((await toolCall("nixos", { tool: "nix", arguments: { action: "channels" } }, harness.tools)).isError, false);
    const executeTool: ExtensionToolContext["executeTool"] = (name, args, options) => {
      assert.ok(isJsonObject(args)); return toolCall(name, args, harness.tools, options?.signal);
    };
    const ctx: ExtensionToolContext = Object.assign(runner.createContext(), { tools: harness.tools, executeTool });
    const code = await executeCodemode("t029-code", { code: 'await tools.nixos({tool:"nix",arguments:{action:"fixture_error"}});' }, undefined, undefined, ctx);
    assert.equal(code.isError, true); assert.match(JSON.stringify(code), /fixture MCP error/);
    const completed = records(f.events).filter(record => record.kind === "group_settled"); assert.equal(completed.length, 3); assert.ok(completed.every(record => record.ok === true));
  } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); if (previous === undefined) delete process.env.MCP_NIXOS_BIN; else process.env.MCP_NIXOS_BIN = previous; await f.close(); }
});

test("mcp-nixos session shutdown cancels and drains the actual active run", async () => {
  const f = await fixture(), previous = process.env.MCP_NIXOS_BIN;
  let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    const binary = join(f.dir, "held-mcp-nixos");
    await fs.writeFile(binary, `#!${fixturePython}
import json, sys, time
for line in sys.stdin:
    frame = json.loads(line)
    if frame.get('method') == 'initialize': print(json.dumps({'jsonrpc':'2.0','id':1,'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture-mcp','version':'1'}}}), flush=True)
    if frame.get('method') == 'tools/call':
        open(${JSON.stringify(join(f.dir, "held-read"))}, 'w').close()
        while True: time.sleep(1)
`, { mode: 0o700 });
    process.env.MCP_NIXOS_BIN = binary;
    const native = await fixtureImport(pathToFileURL(join(sourceRoot, "pi-extensions/mcp-nixos.ts")).href + "?fixture=" + encodeURIComponent(f.dir));
    const harness = await runnerFor(native.default, f.dir); runner = harness.runner;
    const pending = toolCall("nixos", { tool: "nix", arguments: { action: "channels" } }, harness.tools);
    await waitFor(() => existsSync(join(f.dir, "held-read")));
    await runner.emit({ type: "session_shutdown", reason: "quit" });
    const cancelled = await pending;
    assert.equal(cancelled.isError, true); assert.match(JSON.stringify(cancelled), /cancel/i);
    assert.equal(records(f.events).find(record => record.kind === "group_settled")?.ok, true);
    const summary = records(f.events).find(record => record.kind === "shutdown_summary");
    assert.ok(summary); assert.equal(summary.ok, true); assert.equal(summary.unsettledApplies, 0);
  } finally {
    await runner?.emit({ type: "session_shutdown", reason: "quit" });
    if (previous === undefined) delete process.env.MCP_NIXOS_BIN; else process.env.MCP_NIXOS_BIN = previous;
    await f.close();
  }
});

async function r17McpPeer(dir: string, mode: string) {
  const binary = join(dir, "r17-mcp-peer");
  await fs.writeFile(binary, `#!${fixturePython}
import json, os, sys, threading, time
root, mode = ${JSON.stringify(dir)}, ${JSON.stringify(mode)}
closed, init_sent, initialized, reply_sent = (threading.Event() for _ in range(4))
lock = threading.Lock()
threads = []
def trace(kind, **fields):
    with open(root + '/wire.jsonl', 'a') as out: out.write(json.dumps({'kind': kind, **fields}) + '\\n')
def output(data):
    with lock:
        sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
def send(frame): output((json.dumps(frame, ensure_ascii=False) + '\\n').encode())
def initialize():
    if mode == 'timeout-init' or mode == 'abort-init': return
    time.sleep(.025)
    if closed.is_set(): trace('initialize-after-eof'); return
    if mode == 'init-error': send({'jsonrpc':'2.0','id':1,'error':{'code':-32000,'message':'fixture initializer RPC failure'}}); return
    if mode == 'malformed-init': send({'jsonrpc':'2.0','id':1,'result':{'protocolVersion':'2024-11-05'}}); return
    init_sent.set(); trace('initialize-reply')
    send({'jsonrpc':'2.0','id':1,'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture-mcp','version':'1'}}})
def respond():
    if mode == 'timeout-call' or mode == 'abort-call': return
    time.sleep(.025)
    if closed.is_set(): trace('reply-lost-at-eof'); return
    frame = {'jsonrpc':'2.0','id':2,'result':{'content':[{'type':'text','text':'fixture asynchronous reply'}]}}
    r18_content = {
        'r18-unknown': [{'type':'bogus'}],
        'r18-missing-image': [{'type':'image'}],
        'r18-valid-image': [{'type':'image','data':'AQID','mimeType':'image/png'}],
        'r18-valid-audio': [{'type':'audio','data':'AQID','mimeType':'audio/wav'}],
        'r18-mixed-image': [{'type':'text','text':'first owned text'}, {'type':'image','data':'AQID','mimeType':'image/png'}],
        'r18-mixed-unknown': [{'type':'text','text':'first owned text'}, {'type':'bogus'}],
        'r18-valid-text': [{'type':'text','text':'fixture R18 text','annotations':{'audience':['assistant'],'priority':0.5},'_meta':{'fixture':'owned'}}],
        'r18-mixed-text': [{'type':'text','text':'first owned text'}, {'type':'text','text':'second owned text'}],
        'r18-empty': [],
        'r18-empty-text': [{'type':'text','text':''}],
        'r18-malformed-text': [{'type':'text'}],
        'r18-empty-error': [],
    }
    if mode in r18_content: frame['result']['content'] = r18_content[mode]
    if mode == 'r18-empty-error': frame['result']['isError'] = True
    if mode == 'rpc-error': frame = {'jsonrpc':'2.0','id':2,'error':{'code':-32603,'message':'fixture tool RPC failure'}}
    if mode == 'backend-error': frame['result'].update(isError=True, content=[{'type':'text','text':'fixture backend failure'}])
    if mode == 'plain-error': frame['result'].update(isError=False, content=[{'type':'text','text':'Error (ERROR): fixture SSLCertVerificationError'}])
    if mode == 'malformed-tool': frame['result']['content'][0]['text'] = 17
    if mode == 'both-envelope': frame['error'] = {'code':-1,'message':'conflicting reply'}
    if mode == 'invalid-rpc': frame = {'jsonrpc':'2.0','id':2,'error':{'code':'bad','message':'malformed error'}}
    if mode == 'wrong-version': frame['jsonrpc'] = '1.0'
    reply_sent.set(); trace('reply', input_open=not closed.is_set())
    if mode == 'bad-json': output(b'{"jsonrpc":"2.0","id":2,"result":\\n'); return
    if mode == 'oversized': output(b'x' * (1024 * 1024 + 1)); return
    if mode == 'fragmented':
        frame['result']['content'][0]['text'] = 'fixture fragmented 🧪 reply'
        prefix = (json.dumps({'jsonrpc':'2.0','id':77,'result':{'content':[{'type':'text','text':'ignore unrelated'}]}}) + '\\n' + json.dumps({'jsonrpc':'2.0','method':'notifications/message','params':{}}) + '\\n').encode()
        payload = (json.dumps(frame, ensure_ascii=False) + '\\n').encode(); split = payload.index('🧪'.encode()) + 1
        output(prefix + payload[:split]); time.sleep(.025); output(payload[split:]); return
    send(frame)
for line in sys.stdin:
    frame = json.loads(line); method = frame.get('method'); trace('request', method=method)
    if method == 'initialize':
        if mode == 'premature-init': sys.stderr.write('fixture init exit'); sys.exit(7)
        if mode == 'early-reply': send({'jsonrpc':'2.0','id':2,'result':{'content':[]}}); continue
        t = threading.Thread(target=initialize); threads.append(t); t.start()
    if method == 'notifications/initialized': initialized.set()
    if method == 'tools/call':
        if mode == 'premature-call': sys.stderr.write('fixture call exit'); sys.exit(9)
        if not init_sent.is_set() or not initialized.is_set():
            trace('call-before-initialized'); send({'jsonrpc':'2.0','id':2,'error':{'code':-32600,'message':'call preceded initialization'}}); continue
        t = threading.Thread(target=respond); threads.append(t); t.start()
closed.set(); trace('eof', reply_sent=reply_sent.is_set())
for t in threads: t.join()
trace('peer-exit')
`, { mode: 0o700 });
  return binary;
}

async function r17McpModule(dir: string, timeout = 30000) {
  const raw = await fs.readFile(join(sourceRoot, "pi-extensions/mcp-nixos.ts"), "utf8");
  const path = join(dir, "mcp-consumer.ts");
  await fs.writeFile(path, raw.replace('"./lib/lifecycle.ts"', JSON.stringify(join(sourceRoot, "pi-extensions/lib/lifecycle.ts")))
    .replace("const DEFAULT_TIMEOUT_MS = 30000;", "const DEFAULT_TIMEOUT_MS = " + timeout + ";"));
  return fixtureImport(pathToFileURL(path).href);
}

const r17McpCases: [string, RegExp | null][] = [
  ["async", null], ["fragmented", null],
  ["init-error", /fixture initializer RPC failure/], ["malformed-init", /invalid initialize result/],
  ["rpc-error", /fixture tool RPC failure/], ["backend-error", /fixture backend failure/],
  ["plain-error", /Error \(ERROR\): fixture SSLCertVerificationError/],
  ["malformed-tool", /invalid text content/], ["both-envelope", /invalid RPC response envelope/],
  ["invalid-rpc", /invalid RPC error/], ["wrong-version", /invalid RPC response envelope/],
  ["bad-json", /malformed JSON response/], ["oversized", /response exceeded 1 MiB/],
  ["premature-init", /no initialize response.*exit code: 7.*fixture init exit/],
  ["premature-call", /no tools\/call response.*exit code: 9.*fixture call exit/],
  ["early-reply", /tools\/call response before initialize/],
  ["timeout-init", /timed out after 150ms/], ["timeout-call", /timed out after 150ms/],
];
for (const [mode, expectedError] of r17McpCases) {
  test(`R17 actual MCP finite streaming consumer (${mode})`, async () => {
    const f = await fixture(), previous = process.env.MCP_NIXOS_BIN;
    let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      process.env.MCP_NIXOS_BIN = await r17McpPeer(f.dir, mode);
      const native = await r17McpModule(f.dir, mode.startsWith("timeout-") ? 150 : 1500);
      const harness = await runnerFor(native.default, f.dir); runner = harness.runner;
      const started = Date.now();
      const outcome = await toolCall("nixos", { tool: "nix", arguments: { action: "channels" } }, harness.tools);
      assert.equal(outcome.isError, expectedError !== null, JSON.stringify(outcome));
      if (expectedError) assert.match(JSON.stringify(outcome), expectedError);
      else {
        assert.match(JSON.stringify(outcome), mode === "fragmented" ? /fixture fragmented 🧪 reply/ : /fixture asynchronous reply/);
        assert.doesNotMatch(JSON.stringify(outcome), /ignore unrelated/);
      }
      assert.ok(Date.now() - started < 1800, "Reply or bounded timeout must trigger cleanup while peer would otherwise remain on open stdin");
      const wire = records(join(f.dir, "wire.jsonl"));
      const methods = wire.filter(row => row.kind === "request").map(row => row.method);
      if (["init-error", "malformed-init", "premature-init", "early-reply", "timeout-init"].includes(mode)) assert.deepEqual(methods, ["initialize"]);
      else assert.deepEqual(methods, ["initialize", "notifications/initialized", "tools/call"]);
      assert.equal(wire.some(row => row.kind === "call-before-initialized"), false);
      if (expectedError === null) {
        assert.equal(wire.find(row => row.kind === "reply")?.input_open, true);
        assert.equal(wire.find(row => row.kind === "eof")?.reply_sent, true, "EOF belongs to cleanup after the selected reply");
      }
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      const events = records(f.events);
      assert.equal(events.filter(row => row.kind === "group_birth").length, 1);
      assert.equal(events.filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
      assert.equal(events.find(row => row.kind === "shutdown_summary")?.ok, true);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); if (previous === undefined) delete process.env.MCP_NIXOS_BIN; else process.env.MCP_NIXOS_BIN = previous; await f.close(); }
  });
}

for (const phase of ["init", "call"]) {
  test(`R17 actual MCP cancellation drains streaming ${phase} waiter`, async () => {
    const f = await fixture(), previous = process.env.MCP_NIXOS_BIN, abort = new AbortController();
    let runner: InstanceType<typeof ExtensionRunner> | undefined, pending: ReturnType<typeof toolCall> | undefined;
    try {
      process.env.MCP_NIXOS_BIN = await r17McpPeer(f.dir, "abort-" + phase);
      const native = await r17McpModule(f.dir, 1500), harness = await runnerFor(native.default, f.dir); runner = harness.runner;
      pending = toolCall("nixos", { tool: "nix", arguments: { action: "channels" } }, harness.tools, abort.signal);
      await waitFor(() => records(join(f.dir, "wire.jsonl")).some(row => row.kind === "request" && row.method === (phase === "init" ? "initialize" : "tools/call")));
      const started = Date.now(); abort.abort(); const result = await pending;
      assert.equal(result.isError, true); assert.match(JSON.stringify(result), /Operation cancelled/); assert.ok(Date.now() - started < 1000);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
      assert.equal(records(f.events).find(row => row.kind === "shutdown_summary")?.ok, true);
    } finally { abort.abort(); if (pending) await pending; await runner?.emit({ type: "session_shutdown", reason: "quit" }); if (previous === undefined) delete process.env.MCP_NIXOS_BIN; else process.env.MCP_NIXOS_BIN = previous; await f.close(); }
  });
}

test("R17 direct MCP RPC rejection retains integer code and pre-abort creates no process", async () => {
  const f = await fixture(), previous = process.env.MCP_NIXOS_BIN;
  try {
    process.env.MCP_NIXOS_BIN = await r17McpPeer(f.dir, "rpc-error");
    const native = await r17McpModule(f.dir, 1500), tracker = new lifecycle.SessionCleanupTracker("mcp-nixos");
    const groups = new Set<ReturnType<typeof lifecycle.spawnManagedGroup>>();
    await assert.rejects(native.callMcpTool("nix", {}, new AbortController().signal, tracker, groups), (error: unknown) =>
      error instanceof Error && lifecycle.isRecord(error) && error.message === "fixture tool RPC failure" && error.code === -32603);
    assert.equal(groups.size, 0);
    const aborted = new AbortController(); aborted.abort();
    assert.throws(() => native.callMcpTool("nix", {}, aborted.signal, tracker, groups), (error: unknown) => error instanceof Error && error.name === "AbortError");
    assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1);
    assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
  } finally { if (previous === undefined) delete process.env.MCP_NIXOS_BIN; else process.env.MCP_NIXOS_BIN = previous; await f.close(); }
});

const r18ContentCases: [string, string | null][] = [
  ["unknown", null], ["missing-image", null], ["valid-image", null], ["valid-audio", null],
  ["mixed-image", null], ["mixed-unknown", null],
  ["valid-text", "fixture R18 text"], ["mixed-text", "first owned text\nsecond owned text"],
  ["empty", "(empty result)"], ["empty-text", "(empty result)"],
  ["malformed-text", null], ["empty-error", null],
];
for (const [mode, expectedText] of r18ContentCases) {
  test(`R18 actual MCP validates whole content array (${mode})`, async () => {
    const f = await fixture(), previous = process.env.MCP_NIXOS_BIN;
    let runner: InstanceType<typeof ExtensionRunner> | undefined;
    try {
      process.env.MCP_NIXOS_BIN = await r17McpPeer(f.dir, "r18-" + mode);
      const native = await r17McpModule(f.dir, 1500), harness = await runnerFor(native.default, f.dir); runner = harness.runner;
      const outcome = await toolCall("nixos", { tool: "nix", arguments: { action: "channels" } }, harness.tools);
      assert.equal(outcome.isError, expectedText === null, JSON.stringify(outcome));
      if (expectedText === null) {
        assert.match(JSON.stringify(outcome), mode === "empty-error" ? /mcp-nixos tool failed/ : /invalid text content|unsupported non-text content/);
        assert.doesNotMatch(JSON.stringify(outcome), /\(empty result\)|first owned text/, "Invalid/mixed blocks must not deliver empty success or partial text");
      } else assert.deepEqual(outcome.result.content, [{ type: "text", text: expectedText }]);
      const wire = records(join(f.dir, "wire.jsonl"));
      assert.deepEqual(wire.filter(row => row.kind === "request").map(row => row.method), ["initialize", "notifications/initialized", "tools/call"]);
      assert.equal(wire.find(row => row.kind === "reply")?.input_open, true);
      await runner.emit({ type: "session_shutdown", reason: "quit" });
      assert.equal(records(f.events).filter(row => row.kind === "group_birth").length, 1);
      assert.equal(records(f.events).filter(row => row.kind === "group_settled" && row.ok === true).length, 1);
      assert.equal(records(f.events).find(row => row.kind === "shutdown_summary")?.ok, true);
    } finally { await runner?.emit({ type: "session_shutdown", reason: "quit" }); if (previous === undefined) delete process.env.MCP_NIXOS_BIN; else process.env.MCP_NIXOS_BIN = previous; await f.close(); }
  });
}

test("actual ast_edit consumer returns native errors and preserves pre-abort without executing", async () => {
  const f = await fixture();
  try {
    const edit = await fixtureImport(pathToFileURL(join(sourceRoot, "ast-edit-extension.ts")).href), harness = await runnerFor(edit.default, f.dir);
    const result = await toolCall("ast_edit", { ops: [{ pat: "x=>y", out: "z" }], paths: [f.dir] }, harness.tools);
    assert.equal(result.isError, true); assert.match(JSON.stringify(result), /separator/);
    const controller = new AbortController(); controller.abort();
    const aborted = await toolCall("ast_edit", { ops: [{ pat: "x", out: "z" }], paths: [f.dir] }, harness.tools, controller.signal);
    assert.equal(aborted.isError, true);
    await harness.runner.emit({ type: "session_shutdown", reason: "quit" });
  } finally { await f.close(); }
});
