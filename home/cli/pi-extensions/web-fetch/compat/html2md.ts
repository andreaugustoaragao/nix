/**
 * `htmlToMarkdown(html, opts)` — replacement for `@oh-my-pi/pi-natives`'s
 * binding of the same name. Shells out to `pi-rs html2md`, which wraps
 * the same `html-to-markdown-rs` Rust crate omp's napi binding uses.
 *
 * `pi-rs` is installed via `home.packages` in `home/cli/pi.nix`, so it is
 * always on $PATH for the user running pi.
 */

import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";

export interface HtmlToMarkdownOptions {
  /** Strip nav/forms/headers/footers (default true to match omp). */
  cleanContent?: boolean;
  /** Skip <img> references in the output. */
  skipImages?: boolean;
  /** Abort signal forwarded to the subprocess. */
  signal?: AbortSignal;
}

export async function htmlToMarkdown(
  html: string,
  options: HtmlToMarkdownOptions = {},
): Promise<string> {
  const args: string[] = ["html2md"];
  if (options.cleanContent === false) args.push("--no-clean");
  if (options.skipImages) args.push("--skip-images");

  return new Promise<string>((resolve, reject) => {
    const child = spawn("pi-rs", args, {
      stdio: ["pipe", "pipe", "pipe"],
      signal: options.signal,
    });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (c) => out.push(Buffer.from(c)));
    child.stderr.on("data", (c) => err.push(Buffer.from(c)));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve(Buffer.concat(out).toString("utf8"));
      } else {
        reject(
          new Error(
            `pi-rs html2md exited ${code}: ${Buffer.concat(err).toString("utf8").slice(0, 500)}`,
          ),
        );
      }
    });
    child.stdin.on("error", () => {
      /* swallow EPIPE if child exited early */
    });
    child.stdin.write(html);
    child.stdin.end();
  });
}
