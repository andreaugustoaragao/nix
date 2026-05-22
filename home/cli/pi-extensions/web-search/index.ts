/**
 * pi extension: `web_search` tool — multi-provider web search with
 * automatic fallback chain. Forked from oh-my-pi.
 *
 * Active providers (chain order — first available wins, on failure the
 * next one is tried):
 *
 *   Anthropic    ANTHROPIC_API_KEY   (web_search_20250305 server tool)
 *   Tavily       TAVILY_API_KEY
 *   Perplexity   PERPLEXITY_API_KEY  (or PERPLEXITY_COOKIES)
 *   Brave        BRAVE_API_KEY
 *   Jina         JINA_API_KEY
 *   Kimi         KIMI_API_KEY        (Moonshot)
 *   Z.AI / GLM   ZAI_API_KEY
 *   Kagi         KAGI_API_KEY
 *   Synthetic    SYNTHETIC_API_KEY
 *   SearXNG      SEARXNG_ENDPOINT (+ optional SEARXNG_TOKEN / basic auth)
 *
 * The OAuth-bound providers from upstream omp (Gemini, Codex, Exa-MCP,
 * Parallel) remain dropped — they need pi-ai vendoring. Override the
 * order or pin one with `provider`.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import {
  getSearchProvider,
  getSearchProviderLabel,
  resolveProviderChain,
  type SearchParams,
  type SearchProvider,
} from "./provider";
import {
  isSearchProviderId,
  SearchProviderError,
  type SearchProviderId,
  type SearchResponse,
} from "./types";

const SYSTEM_PROMPT =
  "You are a web search engine. Return concise, factual answers grounded in " +
  "the cited sources. Include direct quotes when they sharpen the response.";

function formatResponse(response: SearchResponse): string {
  const parts: string[] = [];

  if (response.answer) {
    parts.push(response.answer);
  }

  if (response.sources.length > 0) {
    parts.push("");
    parts.push("## Sources");
    response.sources.forEach((src, i) => {
      const title = src.title || src.url;
      let line = `[${i + 1}] ${title}`;
      if (src.publishedDate) line += ` (${src.publishedDate})`;
      parts.push(line);
      parts.push(`    ${src.url}`);
      if (src.snippet) {
        const snippet = src.snippet.length > 200
          ? src.snippet.slice(0, 200) + "..."
          : src.snippet;
        parts.push(`    ${snippet.replace(/\n/g, " ")}`);
      }
    });
  }

  if (response.citations && response.citations.length > 0) {
    parts.push("");
    parts.push("## Citations");
    response.citations.forEach((c, i) => {
      const title = c.title || c.url;
      parts.push(`[${i + 1}] ${title}— ${c.url}`);
      if (c.citedText) parts.push(`    “${c.citedText.slice(0, 200)}”`);
    });
  }

  if (response.relatedQuestions && response.relatedQuestions.length > 0) {
    parts.push("");
    parts.push("## Related");
    for (const r of response.relatedQuestions) parts.push(`- ${r}`);
  }

  return parts.join("\n").trim();
}

async function pickProviders(
  pinned: string | undefined,
): Promise<SearchProvider[]> {
  if (pinned && pinned !== "auto") {
    if (!isSearchProviderId(pinned)) {
      throw new Error(`Unknown provider: ${pinned}`);
    }
    const provider = await getSearchProvider(pinned);
    if (await provider.isAvailable()) return [provider];
    // Pinned provider not available — fall back to auto chain.
    return resolveProviderChain();
  }
  return resolveProviderChain();
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "web_search",
    label: "Web Search",
    description:
      "Search the web via a multi-provider fallback chain (Anthropic, " +
      "Tavily, Perplexity, Brave, Jina, Kimi, Z.AI, Kagi, Synthetic, " +
      "SearXNG). Each provider is keyed by an env var (ANTHROPIC_API_KEY, " +
      "TAVILY_API_KEY, BRAVE_API_KEY, etc.). The first available provider " +
      "is used; on failure, the next one in the chain takes over. " +
      "Returns the provider's answer (when supported), cited sources, " +
      "and related queries. Forked from oh-my-pi.",
    parameters: Type.Object({
      query: Type.String({ description: "Search query." }),
      provider: Type.Optional(
        Type.String({
          description:
            "Pin a specific provider (anthropic, tavily, perplexity, brave, " +
            "jina, kimi, zai, kagi, synthetic, searxng). Falls back to " +
            "the auto chain when the pinned provider is not configured. " +
            "Omit or pass 'auto' to use the full chain.",
        }),
      ),
      recency: Type.Optional(
        Type.Union(
          ["day", "week", "month", "year"].map((s) => Type.Literal(s)),
          {
            description: "Temporal filter applied by providers that support it.",
          },
        ),
      ),
      limit: Type.Optional(
        Type.Integer({
          description: "Max sources to return.",
          minimum: 1,
          maximum: 50,
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
      let providers: SearchProvider[];
      try {
        providers = await pickProviders(params.provider);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `web_search: ${msg}` }],
          details: { error: msg },
        };
      }

      if (providers.length === 0) {
        return {
          content: [
            {
              type: "text",
              text:
                "web_search: no providers configured. Set one of " +
                "ANTHROPIC_API_KEY / TAVILY_API_KEY / BRAVE_API_KEY / " +
                "JINA_API_KEY / PERPLEXITY_API_KEY / KIMI_API_KEY / " +
                "ZAI_API_KEY / KAGI_API_KEY / SYNTHETIC_API_KEY, or " +
                "SEARXNG_ENDPOINT.",
            },
          ],
          details: { error: "no_providers" },
        };
      }

      const searchParams: SearchParams = {
        query: params.query,
        limit: params.limit,
        recency: params.recency,
        systemPrompt: SYSTEM_PROMPT,
        signal,
      };

      let lastError: unknown;
      let lastProvider: SearchProvider = providers[0];
      const tried: string[] = [];
      for (const provider of providers) {
        lastProvider = provider;
        tried.push(provider.label);
        try {
          const response = await provider.search(searchParams);
          return {
            content: [{ type: "text", text: formatResponse(response) }],
            details: {
              provider: response.provider,
              providerLabel: provider.label,
              sources: response.sources.length,
              tried,
            },
          };
        } catch (err) {
          lastError = err;
        }
      }

      const baseMessage = formatProviderError(lastError, lastProvider);
      return {
        content: [
          {
            type: "text",
            text:
              providers.length > 1
                ? `All providers failed (${tried.join(", ")}). Last error: ${baseMessage}`
                : baseMessage,
          },
        ],
        details: {
          provider: lastProvider.id,
          providerLabel: lastProvider.label,
          tried,
          error: baseMessage,
        },
      };
    },
  });
}

function formatProviderError(err: unknown, provider: SearchProvider): string {
  if (err instanceof SearchProviderError) {
    if (err.status === 401 || err.status === 403) {
      return `${getSearchProviderLabel(err.provider)} authorization failed (${err.status}). Check API key.`;
    }
    return err.message;
  }
  if (err instanceof Error) return err.message;
  return `Unknown error from ${provider.label}`;
}
