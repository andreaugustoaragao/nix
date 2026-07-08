/**
 * Pi extension: `nixos` tool — bridge to the mcp-nixos MCP server.
 *
 * Deployed by home/cli/pi.nix as ~/.pi/agent/extensions/mcp-nixos.ts.
 * Edit this source and rebuild; do not edit the deployed copy.
 *
 * Pi has no native MCP client, so this acts as one: for each call it
 * spawns `mcp-nixos` (stdio transport, packaged via home.packages),
 * performs the MCP initialize handshake, issues a single tools/call,
 * and returns the text result. mcp-nixos 1.0.3 is stdio-only, so each
 * invocation is a short-lived subprocess — no port, no long-running
 * service. The batch write (initialize + initialized + tools/call,
 * then close stdin) matches how the server drains its stdin loop.
 *
 * Claude Code talks to the same `mcp-nixos` binary directly over its
 * built-in MCP stdio transport (registered via `claude mcp add`); this
 * file only exists because Pi can't.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { StringEnum } from "@earendil-works/pi-ai";
import { spawn } from "node:child_process";

// Resolved on PATH from home.packages (pkgs.mcp-nixos). Overridable
// for testing / non-Nix environments.
const MCP_BIN = process.env.MCP_NIXOS_BIN ?? "mcp-nixos";
const DEFAULT_TIMEOUT_MS = 30000;

// The 18 tools mcp-nixos 1.0.3 exposes (from a live tools/list). Kept
// as a closed enum so the model sees exactly what is callable and pi
// rejects typos before a subprocess is spawned.
const TOOLS = [
  "nixos_search",
  "nixos_info",
  "nixos_channels",
  "nixos_stats",
  "home_manager_search",
  "home_manager_info",
  "home_manager_stats",
  "home_manager_list_options",
  "home_manager_options_by_prefix",
  "darwin_search",
  "darwin_info",
  "darwin_stats",
  "darwin_list_options",
  "darwin_options_by_prefix",
  "nixos_flakes_search",
  "nixos_flakes_stats",
  "nixhub_package_versions",
  "nixhub_find_version",
] as const;

interface JsonRpcResponse {
  jsonrpc: string;
  id?: number | string;
  result?: { content?: Array<{ type: string; text?: string }> };
  error?: { code: number; message: string };
}

/**
 * Spawn mcp-nixos, run one tools/call to completion, return its text.
 * Frames are newline-delimited JSON-RPC (MCP stdio transport).
 */
function callMcpTool(
  tool: string,
  args: Record<string, unknown>,
  signal: AbortSignal | undefined,
): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const child = spawn(MCP_BIN, [], { stdio: ["pipe", "pipe", "pipe"] });

    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`mcp-nixos timed out after ${DEFAULT_TIMEOUT_MS}ms`));
    }, DEFAULT_TIMEOUT_MS);

    const onAbort = () => {
      child.kill("SIGKILL");
      reject(new Error("aborted"));
    };
    signal?.addEventListener("abort", onAbort, { once: true });

    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    };

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    child.stderr.on("data", (d: Buffer) => (stderr += d.toString()));

    child.on("error", (err: Error) => {
      cleanup();
      reject(
        new Error(
          `failed to launch '${MCP_BIN}': ${err.message}. ` +
            `Is pkgs.mcp-nixos on PATH (home.packages)?`,
        ),
      );
    });

    child.on("close", () => {
      cleanup();
      // The tools/call reply carries id 2; scan all newline-delimited
      // frames for it (init reply is id 1, notifications have no id).
      for (const line of stdout.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        let msg: JsonRpcResponse;
        try {
          msg = JSON.parse(trimmed) as JsonRpcResponse;
        } catch {
          continue;
        }
        if (msg.id !== 2) continue;
        if (msg.error) {
          reject(new Error(`mcp-nixos error: ${msg.error.message}`));
          return;
        }
        const text = (msg.result?.content ?? [])
          .filter((c) => c.type === "text" && c.text)
          .map((c) => c.text)
          .join("\n");
        resolve(text || "(empty result)");
        return;
      }
      reject(
        new Error(
          `no tools/call response from mcp-nixos` +
            (stderr ? `; stderr: ${stderr.slice(0, 500)}` : ""),
        ),
      );
    });

    const frames = [
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "pi-mcp-nixos-bridge", version: "1" },
        },
      },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: tool, arguments: args },
      },
    ];
    child.stdin.write(frames.map((f) => JSON.stringify(f)).join("\n") + "\n");
    child.stdin.end();
  });
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "nixos",
    label: "NixOS / nixpkgs lookup",
    description:
      "Query real, current NixOS/nixpkgs data via the mcp-nixos server " +
      "instead of relying on training data (which hallucinates package " +
      "names and option paths). Pick `tool` and pass its `arguments`.\n\n" +
      "Common tools and their arguments:\n" +
      "- nixos_search { query, limit?, channel?, type? }  type ∈ packages|options|programs\n" +
      "- nixos_info { name, type?, channel? }             exact package/option details\n" +
      "- nixos_channels {}                                list channels\n" +
      "- nixos_stats { channel? }\n" +
      "- home_manager_search { query, limit? }            Home Manager options\n" +
      "- home_manager_info { name }\n" +
      "- home_manager_options_by_prefix { option_prefix } e.g. 'programs.git'\n" +
      "- darwin_search { query, limit? } / darwin_info { name }  nix-darwin options\n" +
      "- nixos_flakes_search { query, limit? }            flake packages\n" +
      "- nixhub_package_versions { package_name, limit? } version history\n" +
      "- nixhub_find_version { package_name, version }    find a specific version",
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
      const args = (params.arguments ?? {}) as Record<string, unknown>;
      try {
        const text = await callMcpTool(params.tool, args, signal);
        return {
          content: [{ type: "text", text }],
          details: { tool: params.tool, arguments: args },
        };
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `nixos lookup failed: ${message}` }],
          details: { tool: params.tool, error: message },
        };
      }
    },
  });
}
