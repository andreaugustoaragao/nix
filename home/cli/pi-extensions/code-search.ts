/**
 * pi extension: `code_search` tool — regex search via the pi-rs grep
 * subcommand. Returns hashline-anchored results grouped by file, matching
 * omp's behavior.
 *
 * Each match emits `*LINE+HASH|TEXT` and each context line emits
 * ` LINE+HASH|TEXT`. The model can copy `LINE+HASH` tokens straight into
 * future tool calls that consume hashline anchors.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";

interface PiRsEnvelope {
  content: string;
  details: Record<string, unknown>;
}

function runPiRs(args: string[], signal?: AbortSignal): Promise<PiRsEnvelope> {
  return new Promise((resolve, reject) => {
    const child = spawn("pi-rs", args, {
      stdio: ["ignore", "pipe", "pipe"],
      signal,
    });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (c) => out.push(Buffer.from(c)));
    child.stderr.on("data", (c) => err.push(Buffer.from(c)));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(
          new Error(
            `pi-rs exited ${code}: ${Buffer.concat(err).toString("utf8").slice(0, 500)}`,
          ),
        );
        return;
      }
      try {
        const parsed = JSON.parse(Buffer.concat(out).toString("utf8")) as PiRsEnvelope;
        resolve(parsed);
      } catch (e) {
        reject(new Error(`pi-rs returned non-JSON: ${(e as Error).message}`));
      }
    });
  });
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "code_search",
    label: "Code Search",
    description:
      "Regex search across files / directories using pi-rs (ripgrep-backed). " +
      "Returns hashline-anchored matches grouped by file. Format: `*LINE+HASH|" +
      "TEXT` for match lines, ` LINE+HASH|TEXT` for context lines. Files are " +
      "headed by `# path`. Respects `.gitignore` by default. Multiline mode " +
      "auto-enables when the pattern contains `\\n`. Brace-template strings " +
      "like `${var}` match as literals automatically.",
    parameters: Type.Object({
      pattern: Type.String({ description: "Regex pattern." }),
      paths: Type.Array(Type.String(), {
        description: "Files, directories, or globs to search (1+).",
        minItems: 1,
      }),
      ignore_case: Type.Optional(
        Type.Boolean({ description: "Case-insensitive (default false)." }),
      ),
      no_gitignore: Type.Optional(
        Type.Boolean({ description: "Disable .gitignore (default false)." }),
      ),
      context_before: Type.Optional(
        Type.Integer({
          description: "Lines of context before each match (default 1).",
          minimum: 0,
          maximum: 20,
        }),
      ),
      context_after: Type.Optional(
        Type.Integer({
          description: "Lines of context after each match (default 3).",
          minimum: 0,
          maximum: 20,
        }),
      ),
      limit: Type.Optional(
        Type.Integer({
          description: "Max matches to surface (default 100).",
          minimum: 1,
          maximum: 1000,
        }),
      ),
      skip: Type.Optional(
        Type.Integer({
          description: "Global match offset for pagination (default 0).",
          minimum: 0,
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
      const args: string[] = ["grep", "-e", params.pattern];
      for (const p of params.paths) args.push("-p", p);
      if (params.ignore_case) args.push("-i");
      if (params.no_gitignore) args.push("--no-gitignore");
      if (params.context_before !== undefined)
        args.push("-B", String(params.context_before));
      if (params.context_after !== undefined)
        args.push("-A", String(params.context_after));
      if (params.limit !== undefined) args.push("--limit", String(params.limit));
      if (params.skip !== undefined) args.push("--skip", String(params.skip));

      try {
        const result = await runPiRs(args, signal);
        return {
          content: [{ type: "text", text: result.content }],
          details: result.details,
        };
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: "code_search failed: " + msg }],
          details: { error: msg },
        };
      }
    },
  });
}
