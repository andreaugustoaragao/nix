/**
 * Stubs for the pi-ai OAuth / model surfaces used by the heavy web-search
 * providers (Anthropic, Gemini, Codex). Vendoring pi-ai is significant
 * effort because it pulls in the full OAuth client + model registry; for
 * now we return shapes that cause the providers' `isAvailable()` checks
 * to return false, and the omp provider chain skips them.
 *
 * Concretely:
 *   - `getEnvApiKey(provider)`: returns undefined → no key → unavailable
 *   - `decodeJwt`: returns null payload → token treated as invalid
 *   - `getBundledModels`: returns an empty list → model resolution fails
 *   - OAuth refreshers throw → token refresh fails → unavailable
 *
 * To unlock these providers, vendor the corresponding pi-ai modules and
 * replace these stubs.
 */

/**
 * Look up the provider's standard env var. omp's pi-ai version layers in
 * additional sources (config files, OAuth refresh, etc.); we keep just
 * the env-var lookup because that's what the env-key providers depend
 * on. Naming follows omp's convention: `<PROVIDER>_API_KEY` uppercase.
 */
export function getEnvApiKey(provider: string): string | undefined {
  const norm = provider.toUpperCase().replace(/-/g, "_");
  // Some providers have alternate names omp accepts.
  const candidates = [
    `${norm}_API_KEY`,
    `${norm}_KEY`,
    norm,
  ];
  // Provider-specific aliases.
  if (provider.toLowerCase() === "zai") candidates.push("GLM_API_KEY");
  if (provider.toLowerCase() === "kimi") candidates.push("MOONSHOT_API_KEY");
  if (provider.toLowerCase() === "synthetic") candidates.push("SYNTHETIC_KEY");
  for (const k of candidates) {
    const v = process.env[k];
    if (typeof v === "string" && v.trim().length > 0) return v.trim();
  }
  return undefined;
}

export function decodeJwt(_token: string): { header: unknown; payload: Record<string, unknown> | null } {
  return { header: null, payload: null };
}

export function getBundledModels(): unknown[] {
  return [];
}

export const ANTIGRAVITY_SYSTEM_INSTRUCTION: string = "";

export function getAntigravityUserAgent(): string {
  return "pi/0.0";
}

export function getGeminiCliHeaders(): Record<string, string> {
  return {};
}

export async function refreshAntigravityToken(
  _refreshToken: string,
): Promise<{ accessToken: string; expiresAt: number }> {
  throw new Error(
    "refreshAntigravityToken: pi-ai OAuth stubs are not implemented — " +
      "Antigravity web_search provider is disabled in this build",
  );
}

export async function refreshGoogleCloudToken(
  _refreshToken: string,
): Promise<{ accessToken: string; expiresAt: number }> {
  throw new Error(
    "refreshGoogleCloudToken: pi-ai OAuth stubs are not implemented — " +
      "Gemini CLI web_search provider is disabled in this build",
  );
}
