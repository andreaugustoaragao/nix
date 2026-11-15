import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";
import { isDeepStrictEqual } from "node:util";

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const Text = Type.Object({ type: Type.Literal("text"), text: Type.String({ minLength: 1, maxLength: 6000 }) }, { additionalProperties: false });
const Code = Type.Object({ type: Type.Literal("code"), text: Type.String({ minLength: 1, maxLength: 6000 }) }, { additionalProperties: false });
const Blocks = Type.Object({ action: Type.Union([Type.Literal("deliver"), Type.Literal("clarify")]), blocks: Type.Array(Type.Union([Text, Code]), { minItems: 1, maxItems: 8 }) }, { additionalProperties: false });

export default function chatWorker(pi: ExtensionAPI) {
  const jobFile = process.env.CHAT_SEND_JOB;
  if (!jobFile) throw new Error("CHAT_SEND_JOB missing");
  const directory = dirname(jobFile);
  const raw: unknown = JSON.parse(readFileSync(jobFile, "utf8"));
  if (!record(raw) || typeof raw.operation !== "string" || !/^[a-zA-Z0-9_-]{1,80}$/.test(raw.operation) ||
      typeof raw.alias !== "string" || !/^[a-zA-Z0-9_-]+$/.test(raw.alias) || typeof raw.sender !== "string" ||
      typeof raw.routes_file !== "string" || typeof raw.state_dir !== "string" || typeof raw.send_authorized !== "boolean") {
    throw new Error("Invalid coordinator job envelope");
  }
  const job = { operation: raw.operation, alias: raw.alias, sender: raw.sender, routes: raw.routes_file, state: raw.state_dir, send: raw.send_authorized, mention: raw.mention };
  let requests = 0;
  let toolCalls = 0;
  let running = false;
  let stoppedOnReceipt = false;
  let lastResult: unknown;
  const started = Date.now();
  const log = (event: string, data: unknown) => appendFileSync(join(directory, "telemetry.jsonl"), JSON.stringify({ event, at: Date.now(), data }) + "\n", { mode: 0o600 });
  const result = (value: unknown) => {
    const content = [{ type: "text", text: JSON.stringify(value) }] satisfies Array<{ type: "text"; text: string }>;
    return { content, details: value };
  };

  async function invoke(mode: "deliver" | "status", signal: AbortSignal | undefined, blocks?: unknown) {
    toolCalls++;
    log("tool_start", { mode, toolCalls });
    if (toolCalls > 3 || running) return result({ outcome: "needs_attention", reason: "tool_budget_or_concurrent_call" });
    const payloadFile = join(directory, "payload.json");
    if (mode === "deliver") {
      if (!Array.isArray(blocks) || blocks.length < 1 || blocks.length > 8 || !blocks.every(b => record(b) && ["text", "code"].includes(String(b.type)) && typeof b.text === "string" && b.text.length > 0 && b.text.length <= 6000 && Object.keys(b).every(k => ["type", "text"].includes(k)))) {
        return result({ outcome: "needs_attention", reason: "text_or_code_blocks_required" });
      }
      const payload = { version: 1, blocks, ...(job.mention ? { mention: job.mention } : {}) };
      if (existsSync(payloadFile)) {
        const previous: unknown = JSON.parse(readFileSync(payloadFile, "utf8"));
        if (!isDeepStrictEqual(previous, payload)) return result({ outcome: "needs_attention", reason: "operation_payload_already_bound" });
      } else {
        writeFileSync(payloadFile, JSON.stringify(payload), { mode: 0o600, flag: "wx" });
      }
      try {
        writeFileSync(join(directory, "tool-attempt.json"), JSON.stringify({ at: Date.now(), operation: job.operation }), { mode: 0o600, flag: "wx" });
      } catch (error) {
        if (record(error) && error.code === "EEXIST") return result({ outcome: "needs_attention", reason: "delivery_already_attempted_use_existing_receipt", operation_id: job.operation });
        throw error;
      }
    }
    const args = mode === "deliver"
      ? ["--route", job.alias, "--message", payloadFile, "--routes-file", job.routes, "--state-dir", job.state, "--operation", job.operation, ...(job.send ? ["--send"] : [])]
      : ["status", "--state-dir", job.state, "--operation", job.operation];
    running = true;
    try {
      const output = await new Promise<string>((resolve, reject) => {
        const child = spawn(job.sender, args, { stdio: ["ignore", "pipe", "pipe"], signal });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (chunk: Buffer) => { stdout += chunk.toString(); if (stdout.length > 131072) child.kill(); });
        child.stderr.on("data", (chunk: Buffer) => { stderr = (stderr + chunk.toString()).slice(-1500); });
        child.on("error", reject);
        child.on("close", (code) => {
          log("command_end", { mode, code, stdout: stdout.slice(0, 4096), stderr });
          if (!stdout.trim()) reject(new Error("sender returned no bounded result"));
          else resolve(stdout);
        });
      });
      const parsed: unknown = JSON.parse(output);
      if (!record(parsed) || parsed.operation_id !== job.operation || typeof parsed.outcome !== "string") throw new Error("sender returned invalid operation result");
      const bounded = { outcome: parsed.outcome, reason: parsed.reason, operation_id: parsed.operation_id, send_attempted: parsed.send_attempted };
      log("tool_end", { mode, result: bounded });
      return result(bounded);
    } catch (error) {
      log("tool_error", { mode, error: error instanceof Error ? error.message : "unknown" });
      return result({ outcome: "uncertain", reason: "sender_interrupted_check_status", operation_id: job.operation });
    } finally { running = false; }
  }

  pi.registerTool({ name: "deliver_message", label: "Prepare or deliver the message", description: "Supply text/code blocks for this job. Choose action=deliver for a complete message. If required facts are missing, choose action=clarify with one short text question block; nothing will be posted. Code is raw text without backtick fences. The tool adds the signature. Destination, mentions and preview/send permission are fixed outside your input. Call once; bounded delivery/status and escalation are deterministic.", parameters: Blocks,
    execute: async (_id, params, signal, _update, ctx) => {
      let response;
      if (params.action === "clarify" && params.blocks.length === 1 && params.blocks[0].type === "text" && params.blocks[0].text.length <= 400) {
        response = result({outcome:"needs_attention",reason:"brief_needs_clarification",detail:params.blocks[0].text,operation_id:job.operation});
      } else if (params.action === "deliver") {
        response = await invoke("deliver", signal, params.blocks);
      } else {
        response = result({outcome:"needs_attention",reason:"invalid_delivery_action",operation_id:job.operation});
      }
      if (running) return response;
      if (record(response.details) && response.details.outcome === "uncertain") response = await invoke("status", signal);
      stoppedOnReceipt = true;
      lastResult = response.details;
      log("stop_on_receipt", response.details);
      ctx.abort();
      return response;
    },
  });
  pi.on("session_start", (_event, ctx) => {
    writeFileSync(join(directory, "ready.json"), JSON.stringify({ at: Date.now(), model: ctx.model?.id, provider: ctx.model?.provider, api: ctx.model?.api, tools: pi.getActiveTools(), thinking: pi.getThinkingLevel(), system_prompt: ctx.getSystemPrompt() }), { mode: 0o600 });
    process.stderr.write('{"event":"CHAT_SEND_READY"}\n');
  });
  pi.on("before_agent_start", (event) => log("start", { system_prompt: event.systemPrompt, tools: pi.getActiveTools() }));
  pi.on("before_provider_request", (event, ctx) => {
    requests++;
    if (requests > 4) { log("request_budget_exceeded", { requests }); ctx.abort(); }
    if (!record(event.payload)) return;
    const payload = { ...event.payload };
    if ("max_output_tokens" in payload) payload.max_output_tokens = 2048;
    else if ("max_completion_tokens" in payload) payload.max_completion_tokens = 2048;
    else payload.max_tokens = 2048;
    payload.tool_choice = ctx.model?.api === "openai-responses"
      ? { type: "function", name: "deliver_message" }
      : { type: "function", function: { name: "deliver_message" } };
    log("request", { request: requests, model: ctx.model?.id, api: ctx.model?.api });
    return payload;
  });
  pi.on("after_provider_response", (event) => {
    const keep = new Set(["x-litellm-response-cost", "x-litellm-model-id", "x-litellm-call-id", "x-request-id", "retry-after"]);
    log("response_headers", { request: requests, status: event.status, headers: Object.fromEntries(Object.entries(event.headers).filter(([key]) => keep.has(key.toLowerCase()))) });
  });
  pi.on("provider_stream_event", (event) => {
    const data = event.data;
    if (!record(data)) return;
    if (record(data.usage)) log("wire_usage", { request: requests, api: event.api, id: data.id, usage: data.usage });
    if (record(data.response) && record(data.response.usage)) log("wire_usage", { request: requests, api: event.api, id: data.response.id, usage: data.response.usage });
  });
  pi.on("agent_settled", (event, ctx) => {
    const done = { at: Date.now(), elapsed_ms: Date.now() - started, requests, tool_calls: toolCalls, aborted: event.aborted, intentional_stop_on_receipt: stoppedOnReceipt, model: ctx.model?.id, result: lastResult };
    writeFileSync(join(directory, "done.json"), JSON.stringify(done), { mode: 0o600 });
    log("settled", done);
    ctx.ui.notify("CHAT_SEND_DONE", "info");
    process.stderr.write('{"event":"CHAT_SEND_DONE"}\n');
  });
}
