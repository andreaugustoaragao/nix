/**
 * Compatibility shim for vendored omp web-search providers.
 *
 * Surface needed by the simple env-key providers (Tavily, Brave, Perplexity,
 * Jina, Kagi, Exa, Kimi, Z.AI, Synthetic, SearXNG):
 *   - $env (environment proxy)
 *   - fetchWithRetry (retry-on-5xx fetch wrapper)
 *
 * Surface stubbed unavailable for OAuth-bound providers (Anthropic via
 * pi-ai OAuth, Gemini via Google Antigravity / GCloud, Codex CLI auth):
 * stubs return shapes that make `isAvailable()` return false, so the
 * provider chain skips them and the env-key ones run.
 *
 * The compat boundary is intentionally small so the diff against
 * upstream omp providers stays a one-liner per file (just the import
 * rewrite).
 */

export {
  $env,
  fetchWithRetry,
  getAgentDbPath,
  readSseJson,
} from "./pi-utils";

// pi-ai OAuth/model surfaces. All stubbed.
export {
  ANTIGRAVITY_SYSTEM_INSTRUCTION,
  decodeJwt,
  getAntigravityUserAgent,
  getBundledModels,
  getEnvApiKey,
  getGeminiCliHeaders,
  refreshAntigravityToken,
  refreshGoogleCloudToken,
} from "./pi-ai-stubs";

export { asRecord, asString } from "./type-guards";
export { AgentStorage } from "./agent-storage";

// `settings` mirror from pi-utils. Env-backed feature flags only.
// Default-type the return value as `string` because the vendored
// providers all read string-valued settings (endpoints, tokens). Pass an
// explicit type parameter for non-string keys.
export const settings = {
  get<T = string>(key: string): T | undefined {
    const envKey = `PI_SETTING_${key.replace(/[^A-Z0-9]/gi, "_").toUpperCase()}`;
    const raw = process.env[envKey];
    if (raw === undefined) return undefined;
    if (raw === "true") return true as T;
    if (raw === "false") return false as T;
    const n = Number(raw);
    if (!Number.isNaN(n) && raw.trim() !== "") return n as T;
    return raw as T;
  },
};
