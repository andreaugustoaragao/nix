/** One-shot stdio bridge to mcp-nixos, with session-owned process cleanup. */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { StringDecoder } from "node:string_decoder";
import { StringEnum } from "@earendil-works/pi-ai";
import { SessionCleanupTracker, spawnManagedGroup, combinedSignal, throwIfAborted, isRecord, isOneOf } from "./lib/lifecycle.ts";

// Resolved on PATH from home.packages (pkgs.mcp-nixos). Overridable
// for testing / non-Nix environments.
const MCP_BIN = process.env.MCP_NIXOS_BIN ?? "mcp-nixos";
const DEFAULT_TIMEOUT_MS = 30000;
const InitializeResult = Type.Object({
  protocolVersion: Type.Literal("2024-11-05"),
  capabilities: Type.Record(Type.String(), Type.Unknown()),
  serverInfo: Type.Object({ name: Type.String(), version: Type.String() }),
});
const RpcError = Type.Object({ code: Type.Integer(), message: Type.String() });
const ToolResult = Type.Object({
  content: Type.Array(Type.Object({ type: Type.String() })),
  isError: Type.Optional(Type.Boolean()),
});
const TextContent = Type.Object({ type: Type.Literal("text"), text: Type.String() });
// This bridge exposes the pinned backend's text output only.
const TextContents = Type.Array(TextContent);

// Closed public API from pinned mcp-nixos 2.4.3 server.py.
const TOOLS = ["nix", "nix_versions"] as const;

type ManagedGroup = ReturnType<typeof spawnManagedGroup>;

export function callMcpTool(
  tool: string, args: Record<string, unknown>, signal: AbortSignal,
  tracker: SessionCleanupTracker, activeGroups: Set<ManagedGroup>,
): Promise<string> {
  throwIfAborted(signal);
  const group = spawnManagedGroup("mcp-nixos", tool, MCP_BIN, []);
  activeGroups.add(group);
  const child = group.child;
  let timer: ReturnType<typeof setTimeout>;
  let abort = () => { };
  const response = new Promise<string>((resolve, reject) => {
    let settled = false, stdout = "", stderr = "", responseBytes = 0;
    let phase: "initializing" | "calling" = "initializing";
    const decoder = new StringDecoder("utf8");
    const finish = (error: Error | null, text?: string) => {
      if (settled) return;
      settled = true;
      if (error) reject(error); else resolve(text ?? "(empty result)");
    };
    timer = setTimeout(() => finish(new Error(`mcp-nixos timed out after ${DEFAULT_TIMEOUT_MS}ms`)), DEFAULT_TIMEOUT_MS);
    abort = () => finish(new DOMException("Operation cancelled", "AbortError"));
    signal.addEventListener("abort", abort, { once: true });
    const send = (frame: unknown) => {
      if (settled) return;
      try { child.stdin.write(JSON.stringify(frame) + "\n"); }
      catch (error) { finish(error instanceof Error ? error : new Error(String(error))); }
    };
    child.stdout.on("data", (data: Buffer) => {
      if (settled) return;
      responseBytes += data.length;
      if (responseBytes > 1024 * 1024) { finish(new Error("mcp-nixos response exceeded 1 MiB")); return; }
      stdout += decoder.write(data);
      let end: number;
      while (!settled && (end = stdout.indexOf("\n")) !== -1) {
        const line = stdout.slice(0, end); stdout = stdout.slice(end + 1);
        if (!line.trim()) continue;
        let msg: unknown;
        try { msg = JSON.parse(line); }
        catch { finish(new Error("mcp-nixos malformed JSON response")); return; }
        if (!isRecord(msg) || (msg.id !== 1 && msg.id !== 2)) continue;
        if (msg.id === 2 && phase === "initializing") {
          finish(new Error("mcp-nixos tools/call response before initialize")); return;
        }
        if (msg.id !== (phase === "initializing" ? 1 : 2)) continue;
        const hasError = Object.hasOwn(msg, "error"), hasResult = Object.hasOwn(msg, "result");
        if (msg.jsonrpc !== "2.0" || hasError === hasResult) {
          finish(new Error("mcp-nixos invalid RPC response envelope")); return;
        }
        if (hasError) {
          if (!Check(RpcError, msg.error)) finish(new Error("mcp-nixos invalid RPC error"));
          else finish(Object.assign(new Error(msg.error.message), { code: msg.error.code }));
          return;
        }
        if (phase === "initializing") {
          if (!Check(InitializeResult, msg.result)) { finish(new Error("mcp-nixos invalid initialize result")); return; }
          phase = "calling";
          send({ jsonrpc: "2.0", method: "notifications/initialized" });
          send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: tool, arguments: args } });
          continue;
        }
        if (!Check(ToolResult, msg.result)) { finish(new Error("mcp-nixos invalid tools/call result")); return; }
        if (!Check(TextContents, msg.result.content)) {
          finish(new Error("mcp-nixos invalid text content or unsupported non-text content")); return;
        }
        const text = msg.result.content.map(item => item.text).join("\n");
        // Pinned server validation also returns utils.error's plain-text envelope.
        if (msg.result.isError === true || /^Error \([A-Z][A-Z0-9_]*\):/.test(text.trimStart())) finish(new Error(text || "mcp-nixos tool failed"));
        else finish(null, text || "(empty result)");
        return;
      }
    });
    child.stderr.on("data", (data: Buffer) => { stderr = (stderr + data.toString()).slice(-500); });
    child.on("error", error => finish(new Error(`failed to launch '${MCP_BIN}': ${error.message}`)));
    child.stdin.on("error", error => finish(error));
    child.on("close", (code, closeSignal) => finish(new Error(
      `no ${phase === "initializing" ? "initialize" : "tools/call"} response from mcp-nixos` +
      (code === null ? `; signal: ${closeSignal}` : `; exit code: ${code}`) + (stderr ? "; stderr: " + stderr : ""),
    )));
    if (signal.aborted) { abort(); return; }
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "pi-mcp-nixos-bridge", version: "1" } } });
  });
  return response.finally(async () => {
    clearTimeout(timer);
    signal.removeEventListener("abort", abort);
    const cleanup = group.shutdown(); tracker.trackRetiring(cleanup);
    const outcome = await cleanup; activeGroups.delete(group);
    if (!outcome.ok) throw new Error(outcome.error);
  });
}

export default function (pi: ExtensionAPI) {
  let sessionCtl = new AbortController();
  let tracker = new SessionCleanupTracker("mcp-nixos");
  const activeGroups = new Set<ManagedGroup>();
  const activeRuns = new Set<Promise<unknown>>();
  let sessionId = "unstarted";
  pi.on("session_start", (_event, ctx) => {
    sessionCtl = new AbortController(); tracker = new SessionCleanupTracker("mcp-nixos");
    sessionId = ctx.sessionManager.getSessionId();
  });
  pi.on("session_shutdown", async event => {
    sessionCtl.abort();
    await tracker.runSessionShutdown({ reason: event.reason, sessionId,
      activeCleanups: [...activeGroups].map(group => group.shutdown()), drainPromises: [...activeRuns] });
  });
  pi.registerTool({
    name: "nixos",
    label: "NixOS / nixpkgs lookup",
    description:
      "Query real, current NixOS/nixpkgs data via the mcp-nixos server " +
      "instead of relying on training data (which hallucinates package " +
      "names and option paths). Pick `tool` and pass its `arguments`.\n\n" +
      "mcp-nixos 2.4.3 exposes two tools; the backend validates arguments.\n" +
      "- nix { action, query?, source?, type?, channel?, limit?, version?, system? }\n" +
      "  action: search|info|stats|browse|channels|flake-inputs|cache|store.\n" +
      "  source defaults to nixos; also home-manager, darwin, flakes, flakehub, nixvim, wiki, nix-dev, noogle, nixhub.\n" +
      "  Search packages: {action:'search',query:'hello',type:'packages',channel:'unstable'}.\n" +
      "  Search options: {action:'search',query:'services.nginx',type:'options'}.\n" +
      "  Exact package info: {action:'info',query:'hello',type:'package'}.\n" +
      "  Channels: {action:'channels'}. Home Manager: {action:'search',source:'home-manager',query:'programs.git'}.\n" +
      "- nix_versions { package, version?, limit? } — package history or exact version; limit 1-50.\n" +
      "  Example: {package:'hello',version:'2.12.1'}. Omit optional arguments you do not need.",
    parameters: Type.Object({
      tool: StringEnum([...TOOLS], {
        description: "Which mcp-nixos tool to call.",
      }),
      arguments: Type.Optional(
        Type.Record(Type.String(), Type.Unknown(), {
          description:
            "Arguments object for the chosen tool (see the per-tool list " +
            "in this tool's description). Omit for no-arg tools.",
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
      if (!isOneOf(TOOLS, params.tool)) throw new Error("Unknown mcp-nixos tool");
      const args = isRecord(params.arguments) ? params.arguments : {};
      const callSignal = combinedSignal(sessionCtl.signal, signal);
      try {
        throwIfAborted(callSignal);
        const run = callMcpTool(params.tool, args, callSignal, tracker, activeGroups);
        activeRuns.add(run);
        run.then(() => activeRuns.delete(run), () => activeRuns.delete(run));
        const text = await run;
        return {
          content: [{ type: "text", text }],
          details: { tool: params.tool, arguments: args },
        };
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `nixos lookup failed: ${message}` }],
          details: { tool: params.tool, error: message },
          isError: true,
        };
      }
    },
  });
}
