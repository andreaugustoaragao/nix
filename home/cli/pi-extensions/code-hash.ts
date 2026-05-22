/**
 * pi extension: `code_hash` tool — emits LINE+HASH|TEXT anchored output
 * for a file or text snippet via the pi-rs hash subcommand.
 *
 * Useful when the model needs to obtain hashline anchors for content it
 * already has in context (e.g. to construct a hashline edit patch without
 * re-reading the file through a tool that auto-anchors).
 *
 * Output goes verbatim to the model — no JSON envelope, one anchored line
 * per input line.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";

function runPiRsHash(
  args: string[],
  input: Buffer | undefined,
  signal?: AbortSignal,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn("pi-rs", args, {
      stdio: [input ? "pipe" : "ignore", "pipe", "pipe"],
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
            `pi-rs hash exited ${code}: ${Buffer.concat(err).toString("utf8").slice(0, 500)}`,
          ),
        );
        return;
      }
      resolve(Buffer.concat(out).toString("utf8"));
    });
    if (input && child.stdin) {
      child.stdin.on("error", () => {
        /* swallow EPIPE if child exited */
      });
      child.stdin.write(input);
      child.stdin.end();
    }
  });
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "code_hash",
    label: "Code Hash",
    description:
      "Emit LINE+HASH|TEXT anchored output for a file or inline text. Each " +
      "line gets a stable 2-char content hash (omp hashline format). Use to " +
      "obtain anchors for constructing edit patches when you already have " +
      "the content in context. Exactly one of `path` or `text` must be set.",
    parameters: Type.Object({
      path: Type.Optional(Type.String({ description: "File to hash." })),
      text: Type.Optional(
        Type.String({ description: "Inline text to hash (alternative to path)." }),
      ),
      start_line: Type.Optional(
        Type.Integer({
          description: "First line number for the anchor numbering (default 1).",
          minimum: 1,
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
      const hasPath = typeof params.path === "string" && params.path.length > 0;
      const hasText = typeof params.text === "string";
      if (hasPath === hasText) {
        return {
          content: [
            {
              type: "text",
              text: "code_hash: exactly one of `path` or `text` must be provided",
            },
          ],
          details: { error: "bad_args" },
        };
      }

      const args: string[] = ["hash"];
      if (hasPath) {
        args.push(params.path as string);
      } else {
        args.push("-");
      }
      if (params.start_line !== undefined) {
        args.push("--start-line", String(params.start_line));
      }

      try {
        const stdin = hasText ? Buffer.from(params.text as string, "utf8") : undefined;
        const text = await runPiRsHash(args, stdin, signal);
        return {
          content: [{ type: "text", text }],
          details: {
            source: hasPath ? params.path : "(inline)",
            lines: text.split("\n").length,
          },
        };
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: "code_hash failed: " + msg }],
          details: { error: msg },
        };
      }
    },
  });
}
