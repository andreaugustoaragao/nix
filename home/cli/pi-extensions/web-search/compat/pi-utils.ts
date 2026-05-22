/**
 * pi-utils subset used by the simple env-key web-search providers.
 */

import * as os from "node:os";
import * as path from "node:path";

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

/**
 * Retrying fetch wrapper. Mirrors omp's behavior loosely: GET requests
 * are retried up to `retries` times on network errors and 5xx; POST is
 * retried only on network errors.
 */
export interface FetchRetryOptions extends RequestInit {
  retries?: number;
  retryDelayMs?: number;
  timeoutMs?: number;
}

export async function fetchWithRetry(
  url: string,
  options: FetchRetryOptions = {},
): Promise<Response> {
  const { retries = 2, retryDelayMs = 500, timeoutMs, ...init } = options;
  const method = (init.method ?? "GET").toUpperCase();
  let lastError: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const controller = new AbortController();
      const merged = init.signal
        ? AbortSignal.any([init.signal, controller.signal])
        : controller.signal;
      const timer = timeoutMs ? setTimeout(() => controller.abort(), timeoutMs) : null;
      try {
        const res = await fetch(url, { ...init, signal: merged });
        if (!res.ok && res.status >= 500 && method === "GET" && attempt < retries) {
          lastError = new Error(`HTTP ${res.status}`);
        } else {
          return res;
        }
      } finally {
        if (timer) clearTimeout(timer);
      }
    } catch (err) {
      lastError = err;
      if (attempt === retries) throw err;
    }
    await new Promise((r) => setTimeout(r, retryDelayMs * (attempt + 1)));
  }
  throw lastError ?? new Error("fetchWithRetry: exhausted retries");
}

/**
 * Per-user agent db path. omp uses this for caching session metadata; the
 * env-key providers only call it when they need to cache OAuth tokens
 * (Anthropic, Gemini), which our stubs disable. We still return a path
 * so the providers don't crash importing this.
 */
export function getAgentDbPath(): string {
  return path.join(os.homedir(), ".pi", "agent", "agent.db");
}

/**
 * SSE chunk → JSON async iterator. omp's signature is
 * `(body, signal?) => AsyncIterable<T>` where body is a fetch Response
 * body stream. We support both forms here so the vendored providers
 * (whose OAuth code paths are disabled in this fork anyway) type-check.
 */
export async function* readSseJson<T = unknown>(
  source: string | ReadableStream<Uint8Array> | null,
  _signal?: AbortSignal,
): AsyncIterableIterator<T> {
  if (source === null) return;
  let text: string;
  if (typeof source === "string") {
    text = source;
  } else {
    const decoder = new TextDecoder();
    text = "";
    const reader = source.getReader();
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        text += decoder.decode(value, { stream: true });
      }
      text += decoder.decode();
    } finally {
      reader.releaseLock();
    }
  }
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (!payload || payload === "[DONE]") continue;
    try {
      yield JSON.parse(payload) as T;
    } catch {
      // ignore malformed SSE lines
    }
  }
}
