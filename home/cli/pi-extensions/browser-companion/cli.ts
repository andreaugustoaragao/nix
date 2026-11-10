import { spawn } from "node:child_process";

export const BROWSER_TASK = "browser-task";
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const PAGE = /^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,127}$/;

export interface Task {
  task: string;
  label: string;
  profile: "development" | "accounts";
  state: "active" | "kept" | "finished";
  pages: Record<string, string>;
  cleanup_at?: number | null;
}

export type Runner = (args: string[], input?: unknown, signal?: AbortSignal) => Promise<unknown>;

export function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// Browser labels, CLI errors, and artifact paths are untrusted terminal text.
export function display(value: string): string {
  return value.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g, " ")
    .slice(0, 240);
}

export function parseTask(value: unknown, expectedId?: string): Task {
  if (!record(value) || typeof value.task !== "string" || !UUID.test(value.task)
    || (expectedId !== undefined && value.task !== expectedId)
    || typeof value.label !== "string"
    || !["development", "accounts"].includes(String(value.profile))
    || !["active", "kept", "finished"].includes(String(value.state))
    || !record(value.pages)
    || Object.entries(value.pages).some(([name, target]) => !PAGE.test(name) || typeof target !== "string")) {
    throw new Error("Invalid browser-task record; no task was adopted.");
  }
  return value as unknown as Task;
}

export function validateUrl(value: string): string {
  const url = value.trim();
  if (!url || url === "about:blank") return "about:blank";
  const parsed = new URL(url);
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) {
    throw new Error("Use an HTTP(S) URL without embedded credentials, or about:blank.");
  }
  return url;
}

/** Only the managed CLI is used; no shell, browser discovery, or raw CDP. */
export const runBrowserTask: Runner = (args, input, signal) => new Promise((resolve, reject) => {
  if (signal?.aborted) { reject(new Error("Browser command cancelled.")); return; }
  const child = spawn(BROWSER_TASK, args, { stdio: ["pipe", "pipe", "pipe"] });
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  let bytes = 0;
  let failure: Error | undefined;
  let escalation: ReturnType<typeof setTimeout> | undefined;
  const stop = (message: string) => {
    if (failure) return;
    failure = new Error(`${message} Inspect task state before retrying.`);
    child.kill("SIGTERM");
    escalation = setTimeout(() => child.kill("SIGKILL"), 2000);
    escalation.unref();
  };
  const abort = () => stop("Browser command cancelled.");
  const timer = setTimeout(() => stop("Browser command timed out."), 35000);
  timer.unref();
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) abort();
  const collect = (chunks: Buffer[], chunk: Buffer) => {
    bytes += chunk.length;
    if (bytes > 1024 * 1024) stop("Browser command output exceeded 1 MiB.");
    else chunks.push(chunk);
  };
  child.stdout.on("data", chunk => collect(stdout, chunk));
  child.stderr.on("data", chunk => collect(stderr, chunk));
  child.stdin.on("error", () => { /* EPIPE is reported by the child's exit status. */ });
  child.once("error", error => { failure = new Error(`Cannot run browser-task: ${error.message}`); });
  child.once("close", code => {
    clearTimeout(timer);
    if (escalation) clearTimeout(escalation);
    signal?.removeEventListener("abort", abort);
    if (failure) { reject(failure); return; }
    if (code !== 0) {
      reject(new Error(`browser-task failed: ${display(Buffer.concat(stderr).toString("utf8")) || `exit ${code}`}`));
      return;
    }
    try { resolve(JSON.parse(Buffer.concat(stdout).toString("utf8"))); }
    catch { reject(new Error("browser-task returned invalid JSON. Inspect task state before retrying.")); }
  });
  child.stdin.end(input === undefined ? undefined : JSON.stringify(input));
});
