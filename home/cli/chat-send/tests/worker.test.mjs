import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import extension from "../scripts/worker.ts";

const blocks = [{ type: "text", text: "A harmless fixture paragraph." }, { type: "code", text: "git status --short" }];
function setup(extra = {}) {
  const directory = mkdtempSync(join(tmpdir(), "pi-chat-worker-test-"));
  const job = { operation: "fixed-operation", alias: "fixture-route", sender: resolve(import.meta.dirname, "fake_sender.py"), routes_file: join(directory, "routes.json"), state_dir: join(directory, "state"), send_authorized: true, ...extra };
  const file = join(directory, "job.json"); writeFileSync(file, JSON.stringify(job)); process.env.CHAT_SEND_JOB = file;
  const hooks = new Map(); const tools = new Map(); let aborts = 0;
  const context = { model: { id: "fixture-model", provider: "fixture", api: "openai-completions" }, getSystemPrompt: () => "Compact fixture system", abort: () => { aborts++; }, ui: { notify: () => {} } };
  const api = { registerTool: definition => tools.set(definition.name, definition), on: (name, handler) => hooks.set(name, handler), getThinkingLevel: () => "low", getActiveTools: () => [...tools.keys()] };
  const create = () => extension(api);
  const calls = () => existsSync(join(directory, "fake-calls.jsonl")) ? readFileSync(join(directory, "fake-calls.jsonl"), "utf8").trim().split("\n").map(JSON.parse) : [];
  return { directory, job, context, hooks, tools, create, calls, aborts: () => aborts, cleanup: () => rmSync(directory, { recursive: true, force: true }) };
}

test("delivery clamps recipient/operation and stops after the durable tool result", async () => {
  const h = setup(); try {
    h.create(); assert.deepEqual([...h.tools.keys()], ["deliver_message"]);
    const output = await h.tools.get("deliver_message").execute("call", { action: "deliver", blocks, route: "other", operation: "other" }, undefined, undefined, h.context);
    assert.equal(output.details.outcome, "sent"); assert.equal(h.aborts(), 1);
    const [call] = h.calls(); assert.equal(h.calls().length, 1);
    assert.equal(call.args[call.args.indexOf("--route") + 1], "fixture-route");
    assert.equal(call.args[call.args.indexOf("--operation") + 1], "fixed-operation");
    const payload = JSON.parse(readFileSync(join(h.directory, "payload.json"), "utf8"));
    assert.deepEqual(payload.blocks, blocks);
  } finally { h.cleanup(); }
});

test("an uncertain attempt gets one read-only status and no second send", async () => {
  const h = setup({ fixture_outcome: "uncertain", fixture_status: "sent" }); try {
    h.create(); const output = await h.tools.get("deliver_message").execute("call", { action: "deliver", blocks }, undefined, undefined, h.context);
    assert.equal(output.details.outcome, "sent"); assert.deepEqual(h.calls().map(c => c.mode), ["deliver", "status"]);
    assert.equal(h.calls().filter(c => c.args.includes("--send")).length, 1); assert.equal(h.aborts(), 1);
  } finally { h.cleanup(); }
});

test("uncertainty is latched across repeated calls and a restarted extension", async () => {
  const h = setup({ fixture_outcome: "uncertain", fixture_status: "uncertain" }); try {
    h.create(); const tool=h.tools.get("deliver_message");
    await tool.execute("one", { action: "deliver", blocks }, undefined, undefined, h.context);
    const second=await tool.execute("two", { action: "deliver", blocks }, undefined, undefined, h.context);
    assert.equal(second.details.reason,"delivery_already_attempted_use_existing_receipt");
    h.create(); const restarted=await h.tools.get("deliver_message").execute("three",{ action: "deliver", blocks },undefined,undefined,h.context);
    assert.equal(restarted.details.reason,"delivery_already_attempted_use_existing_receipt");
    assert.deepEqual(h.calls().map(c=>c.mode),["deliver","status"]);
  } finally { h.cleanup(); }
});

test("a changed payload cannot overwrite or resubmit a bound operation", async () => {
  const h = setup(); try {
    h.create(); const tool = h.tools.get("deliver_message"); await tool.execute("one", { action: "deliver", blocks }, undefined, undefined, h.context);
    const first = readFileSync(join(h.directory, "payload.json"), "utf8");
    const changed = [{ type: "text", text: "Changed text" }, blocks[1]];
    const output = await tool.execute("two", { action: "deliver", blocks: changed }, undefined, undefined, h.context);
    assert.equal(output.details.reason, "operation_payload_already_bound"); assert.equal(h.calls().length, 1);
    assert.equal(readFileSync(join(h.directory, "payload.json"), "utf8"), first);
  } finally { h.cleanup(); }
});

test("an invalid authorization cannot register tools or run a sender", () => {
  const h = setup({ send_authorized: "true" }); try { assert.throws(h.create, /Invalid coordinator job envelope/); assert.equal(h.calls().length, 0); } finally { h.cleanup(); }
});

test("invalid blocks stop before any payload binding or sender call", async () => {
  const h = setup(); try {
    h.create(); const output = await h.tools.get("deliver_message").execute("call", { action: "deliver", blocks: [{type:"html", text:"wrong"}] }, undefined, undefined, h.context);
    assert.equal(output.details.outcome, "needs_attention"); assert.equal(h.calls().length, 0); assert.equal(existsSync(join(h.directory, "payload.json")), false);
  } finally { h.cleanup(); }
});

test("provider contracts cap output and force the same narrow tool in both APIs", () => {
  const h = setup(); try {
    h.create(); const hook = h.hooks.get("before_provider_request");
    const chat = hook({ payload: { max_tokens: 100000 } }, h.context);
    assert.equal(chat.max_tokens, 2048); assert.deepEqual(chat.tool_choice, { type: "function", function: { name: "deliver_message" } });
    const response = hook({ payload: { max_output_tokens: 100000 } }, { ...h.context, model: { ...h.context.model, api: "openai-responses" } });
    assert.equal(response.max_output_tokens, 2048); assert.deepEqual(response.tool_choice, { type: "function", name: "deliver_message" });
    h.hooks.get("after_provider_response")({ status: 200, headers: { authorization: "secret-fixture", "set-cookie": "cookie-fixture", "x-litellm-response-cost": "0.001" } });
    const logs = readFileSync(join(h.directory, "telemetry.jsonl"), "utf8"); assert.doesNotMatch(logs, /secret-fixture|cookie-fixture/); assert.match(logs, /0.001/);
  } finally { h.cleanup(); }
});

test("concurrent tool calls cannot dispatch another sender", async () => {
  const h = setup({ fixture_delay: 0.08 }); try {
    h.create(); const tool = h.tools.get("deliver_message");
    const first = tool.execute("one", { action: "deliver", blocks }, undefined, undefined, h.context);
    const second = await tool.execute("two", { action: "deliver", blocks }, undefined, undefined, h.context);
    assert.equal(second.details.reason, "tool_budget_or_concurrent_call"); await first; assert.equal(h.calls().length, 1);
  } finally { h.cleanup(); }
});


test("default preview supports plain text without send permission or benchmark label", async () => {
  const h=setup({send_authorized:false});try {
    h.create();await h.tools.get("deliver_message").execute("one",{action:"deliver",blocks:[blocks[0]]},undefined,undefined,h.context);
    assert.equal(h.calls().length,1);assert.equal(h.calls()[0].args.includes("--send"),false);
    assert.deepEqual(JSON.parse(readFileSync(join(h.directory,"payload.json"),"utf8")),{version:1,blocks:[blocks[0]]});
  } finally {h.cleanup();}
});

test("trusted mention is retained outside model arguments", async () => {
  const mention={email:"person@example.com",query:"Person"};const h=setup({mention});try {
    h.create();await h.tools.get("deliver_message").execute("one",{action:"deliver",blocks,mention:{email:"wrong@example.com"}},undefined,undefined,h.context);
    assert.deepEqual(JSON.parse(readFileSync(join(h.directory,"payload.json"),"utf8")).mention,mention);
  } finally {h.cleanup();}
});


test("missing facts return to caller without sender invocation or payload binding", async () => {
  const h=setup();try {
    h.create();const output=await h.tools.get("deliver_message").execute("one",{action:"clarify",blocks:[{type:"text",text:"What date should I include?"}]},undefined,undefined,h.context);
    assert.equal(output.details.reason,"brief_needs_clarification");assert.equal(h.calls().length,0);
    assert.equal(existsSync(join(h.directory,"payload.json")),false);assert.equal(h.aborts(),1);
  } finally {h.cleanup();}
});


test("an unknown action never invokes the sender", async () => {
  const h=setup();try {
    h.create();const output=await h.tools.get("deliver_message").execute("one",{action:"unknown",blocks},undefined,undefined,h.context);
    assert.equal(output.details.reason,"invalid_delivery_action");assert.equal(h.calls().length,0);
  } finally {h.cleanup();}
});
