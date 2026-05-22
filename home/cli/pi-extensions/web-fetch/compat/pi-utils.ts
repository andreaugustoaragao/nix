/**
 * Compact reimplementation of the subset of `@oh-my-pi/pi-utils` actually
 * used by the vendored web-fetch scrapers. Only the helpers reached by at
 * least one scraper are implemented; anything else is intentionally absent
 * so port regressions show up at type-check time rather than at runtime.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn, type SpawnOptionsWithoutStdio } from "node:child_process";
import { Buffer } from "node:buffer";

// ---------------------------------------------------------------------------
// $env — environment proxy
// ---------------------------------------------------------------------------

export const $env: Record<string, string | undefined> = new Proxy(
  {} as Record<string, string | undefined>,
  {
    get(_target, key: string) {
      return process.env[key];
    },
    has(_target, key: string) {
      return key in process.env;
    },
  },
);

// ---------------------------------------------------------------------------
// Type guards
// ---------------------------------------------------------------------------

export function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

export function tryParseJson<T = unknown>(text: string): T | null {
  try {
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const NF = new Intl.NumberFormat("en-US");

export function formatNumber(n: number | string | bigint | undefined | null): string {
  if (n === undefined || n === null || n === "") return "";
  const num = typeof n === "string" ? Number(n) : Number(n);
  if (!Number.isFinite(num)) return String(n);
  return NF.format(num);
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

export function isEnoent(e: unknown): boolean {
  return (
    e instanceof Error &&
    "code" in e &&
    (e as NodeJS.ErrnoException).code === "ENOENT"
  );
}

/** Return omp's per-user agent directory; we map to `~/.pi/agent`. */
export function getAgentDir(): string {
  return path.join(os.homedir(), ".pi", "agent");
}

/**
 * Bun.Glob replacement: list files in `dirname(prefix)` whose basenames
 * start with `basename(prefix)`. Optional suffix filter. Returns
 * absolute paths. Used by scrapers that scan for files matching a
 * temp-file prefix pattern.
 */
export async function globByPrefix(
  prefix: string,
  suffix: string = "",
): Promise<string[]> {
  const fsp = await import("node:fs/promises");
  const dir = path.dirname(prefix);
  const base = path.basename(prefix);
  try {
    const entries = await fsp.readdir(dir);
    return entries
      .filter((e) => e.startsWith(base) && e.endsWith(suffix))
      .map((e) => path.resolve(dir, e));
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Frontmatter — supports the YAML-ish subset omp scrapers need. Matches the
// shape of omp's `parseFrontmatter`: returns `{ frontmatter, body }`.
// ---------------------------------------------------------------------------

export interface FrontmatterResult {
  frontmatter: Record<string, unknown>;
  body: string;
}

export interface FrontmatterOptions {
  /** Identifier surfaced in error messages (e.g. source URL). */
  source?: string;
  /** Fallback values merged under any parsed entries. */
  fallback?: Record<string, unknown>;
}

export function parseFrontmatter(
  text: string,
  options: FrontmatterOptions = {},
): FrontmatterResult {
  // Match `---\n...\n---\n` at the very start.
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!m) {
    return { frontmatter: { ...(options.fallback ?? {}) }, body: text };
  }
  const body = text.slice(m[0].length);
  const frontmatter: Record<string, unknown> = { ...(options.fallback ?? {}) };
  for (const rawLine of m[1].split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const colon = line.indexOf(":");
    if (colon === -1) continue;
    const key = line.slice(0, colon).trim();
    let value: string = line.slice(colon + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    frontmatter[key] = value;
  }
  return { frontmatter, body };
}

// ---------------------------------------------------------------------------
// Snowflake — monotonic-ish 64-bit-ish ids. omp uses BigInt; we keep the
// shape and rely on hex strings for stability.
// ---------------------------------------------------------------------------

let snowflakeSeq = 0;

export const Snowflake = {
  /** Generate a new unique-ish hex string. omp returns a 16-char hex; we
   * return a similarly-shaped string. Sufficient for temp-file naming. */
  next(): string {
    snowflakeSeq = (snowflakeSeq + 1) & 0xffff;
    const ts = Date.now().toString(16).padStart(12, "0");
    const seq = snowflakeSeq.toString(16).padStart(4, "0");
    return `${ts}${seq}`;
  },
  /** Alias kept for forward compatibility. */
  generate(): string {
    return Snowflake.next();
  },
};

// ---------------------------------------------------------------------------
// Logger — minimal console-backed structured logger. omp uses winston;
// scrapers only call `logger.info`/`warn`/`error`/`debug`, so a plain
// passthrough is enough.
// ---------------------------------------------------------------------------

export const logger = {
  info: (...args: unknown[]) => console.error("[info]", ...args),
  warn: (...args: unknown[]) => console.error("[warn]", ...args),
  error: (...args: unknown[]) => console.error("[error]", ...args),
  debug: (...args: unknown[]) => {
    if (process.env.PI_DEBUG) console.error("[debug]", ...args);
  },
};

// ---------------------------------------------------------------------------
// ptree — promise / abort / subprocess helpers used by scrapers.
//
// Surface needed (grep'd from the scrapers):
//   - ptree.combineSignals(signal | timeoutMs, ...)
//   - ptree.exec(cmd, opts) — for shelling out to external tools
// ---------------------------------------------------------------------------

export namespace ptree {
  export type SignalValue = AbortSignal | number | undefined;

  /**
   * Combine zero or more abort signals and/or timeouts into one signal.
   * Mirrors omp's `combineSignals` exactly: numbers are treated as
   * milliseconds and converted to `AbortSignal.timeout(...)`.
   */
  export function combineSignals(...signals: SignalValue[]): AbortSignal | undefined {
    let timeout: number | undefined;
    const real: AbortSignal[] = [];
    for (const s of signals) {
      if (s instanceof AbortSignal) {
        if (s.aborted) return s;
        real.push(s);
      } else if (typeof s === "number" && s > 0) {
        timeout = timeout === undefined ? s : Math.min(timeout, s);
      }
    }
    if (timeout !== undefined) {
      real.push(AbortSignal.timeout(timeout));
    }
    if (real.length === 0) return undefined;
    if (real.length === 1) return real[0];
    return AbortSignal.any(real);
  }

  export interface ExecResult {
    stdout: string;
    stderr: string;
    exitCode: number | null;
    /** `true` iff exit code is 0. Mirrors omp's ExecResult shape so
     * scrapers can check `if (result.ok)`. */
    ok: boolean;
  }

  export interface ExecOptions {
    stdin?: string | Buffer;
    cwd?: string;
    env?: Record<string, string | undefined>;
    signal?: AbortSignal;
    timeout?: number; // ms
  }

  /**
   * Spawn a subprocess and collect stdout/stderr. Used by scrapers that
   * shell out to `gh`, `cosign`, etc. Cmd is an array; index 0 is the
   * executable, rest are args (matches omp's API).
   */
  export async function exec(
    cmd: string[],
    opts: ExecOptions = {},
  ): Promise<ExecResult> {
    if (cmd.length === 0) {
      throw new Error("ptree.exec: empty command");
    }
    const [bin, ...args] = cmd;
    const combined = combineSignals(opts.signal, opts.timeout);
    return new Promise((resolve, reject) => {
      const env = (opts.env ?? process.env) as NodeJS.ProcessEnv;
      const spawnOpts: SpawnOptionsWithoutStdio = {
        cwd: opts.cwd,
        env,
        signal: combined,
      };
      const child = spawn(bin, args, spawnOpts);
      const out: Buffer[] = [];
      const err: Buffer[] = [];
      child.stdout.on("data", (c) => out.push(Buffer.from(c)));
      child.stderr.on("data", (c) => err.push(Buffer.from(c)));
      child.on("error", reject);
      child.on("close", (code) => {
        resolve({
          stdout: Buffer.concat(out).toString("utf8"),
          stderr: Buffer.concat(err).toString("utf8"),
          exitCode: code,
          ok: code === 0,
        });
      });
      if (opts.stdin !== undefined) {
        child.stdin.on("error", () => {
          /* swallow EPIPE if child exited early */
        });
        child.stdin.write(opts.stdin);
        child.stdin.end();
      }
    });
  }
}

// Re-export $envpos because some omp internal callsites use it; the
// scrapers do not, but a stub keeps drop-in compatibility if a future
// vendor pass pulls in additional files.
export function $envpos(_keys: string | string[], def: number): number {
  return def;
}

// ---------------------------------------------------------------------------
// formatBytes — used by dockerhub/ollama scrapers. omp's version lives in
// `tools/render-utils.ts`; this is a faithful clone (1024-based, KiB/MiB).
// ---------------------------------------------------------------------------

export function formatBytes(bytes: number | undefined | null): string {
  if (bytes === undefined || bytes === null || !Number.isFinite(bytes) || bytes < 0) {
    return "-";
  }
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i += 1;
  }
  return `${n < 10 && i > 0 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
}

// ---------------------------------------------------------------------------
// settings — minimal env-backed feature-flag surface. omp's settings
// system is layered (defaults ← file ← env ← session). For our purposes
// scrapers only call `.get(key)` for feature toggles (e.g.
// `providers.parallelFetch`). We return undefined for everything, which
// disables every gated code path — the scraper falls back to its built-in
// behavior. Set `PI_SETTING_<KEY>` env vars to override.
// ---------------------------------------------------------------------------

export const settings = {
  get<T = unknown>(key: string): T | undefined {
    const envKey = `PI_SETTING_${key.replace(/[^A-Z0-9]/gi, "_").toUpperCase()}`;
    const raw = process.env[envKey];
    if (raw === undefined) return undefined;
    if (raw === "true") return true as T;
    if (raw === "false") return false as T;
    const num = Number(raw);
    if (!Number.isNaN(num) && raw.trim() !== "") return num as T;
    return raw as T;
  },
};

// ---------------------------------------------------------------------------
// ensureTool — verify an external binary is on $PATH. omp installs missing
// tools through its plugin manager; we just check and report. youtube
// scraper uses this for yt-dlp.
// ---------------------------------------------------------------------------

export interface EnsureToolOptions {
  signal?: AbortSignal;
  silent?: boolean;
}

/**
 * Return the absolute path to `name` on $PATH, or `undefined` when the
 * binary cannot be found. Matches omp's `ensureTool` return shape.
 */
export async function ensureTool(
  name: string,
  _options: EnsureToolOptions = {},
): Promise<string | undefined> {
  try {
    const which = await ptree.exec(["which", name]);
    if (!which.ok) return undefined;
    const p = which.stdout.trim();
    return p.length > 0 ? p : undefined;
  } catch {
    return undefined;
  }
}

// Anything else the scrapers reach for can be added here. Keep this file
// the only canonical source for compat surface so the diff against omp
// stays a one-liner per scraper (just the import rewrite).
