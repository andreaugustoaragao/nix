/**
 * pi extension: `code_summary` tool — tree-sitter elision summary via the
 * pi-rs summary subcommand. Returns the file's interesting structure
 * (imports, signatures, top-level statements) with function bodies and
 * large literals collapsed into `...` markers. Hashline-anchored output.
 *
 * Use this instead of `read` when you only need a file's shape, not its
 * full body. Typical token savings on a 500-line source file: 70-85%.
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
        resolve(JSON.parse(Buffer.concat(out).toString("utf8")) as PiRsEnvelope);
      } catch (e) {
        reject(new Error(`pi-rs returned non-JSON: ${(e as Error).message}`));
      }
    });
  });
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "code_summary",
    label: "Code Summary",
    description:
      "Tree-sitter structural summary of a source file. Returns the file's " +
      "outline (imports, signatures, top-level statements, type decls) with " +
      "function bodies and large literals elided as `...`. Hashline-anchored " +
      "output. Supports 50+ languages (Rust, TypeScript, Go, Python, etc.). " +
      "Useful for getting a quick map of an unfamiliar file without spending " +
      "tokens on bodies. Use `read` for the full text.",
    parameters: Type.Object({
      path: Type.String({ description: "Path to the source file." }),
      lang: Type.Optional(
        Type.String({
          description:
            "Language alias override (e.g. 'rust', 'typescript', 'go'). " +
            "Inferred from the file extension when omitted.",
        }),
      ),
      min_body_lines: Type.Optional(
        Type.Integer({
          description:
            "Minimum total lines for a body/literal node before it is " +
            "elided. Default 4.",
          minimum: 2,
          maximum: 50,
        }),
      ),
      min_comment_lines: Type.Optional(
        Type.Integer({
          description:
            "Minimum total lines for a multiline comment before it is " +
            "elided. Default 6.",
          minimum: 4,
          maximum: 50,
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
      const args: string[] = ["summary", params.path];
      if (params.lang) args.push("--lang", params.lang);
      if (params.min_body_lines !== undefined)
        args.push("--min-body-lines", String(params.min_body_lines));
      if (params.min_comment_lines !== undefined)
        args.push("--min-comment-lines", String(params.min_comment_lines));

      try {
        const result = await runPiRs(args, signal);
        return {
          content: [{ type: "text", text: result.content }],
          details: result.details,
        };
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: "code_summary failed: " + msg }],
          details: { error: msg },
        };
      }
    },
  });
}
