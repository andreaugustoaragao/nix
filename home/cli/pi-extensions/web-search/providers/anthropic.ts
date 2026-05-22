/**
 * Anthropic Web Search Provider
 *
 * Calls Anthropic's Messages API with the `web_search_20250305` server-side
 * tool. Claude executes searches itself and returns a synthesized answer +
 * web_search_tool_result blocks (sources) + inline text citations.
 *
 * Pricing (in addition to model token costs):
 *   $10 per 1000 web_search invocations
 *
 * Env vars:
 *   ANTHROPIC_API_KEY                  - required
 *   ANTHROPIC_WEB_SEARCH_MODEL         - override model (default: claude-3-5-haiku-latest)
 *   ANTHROPIC_WEB_SEARCH_MAX_USES      - cap searches per request (default: 3)
 *   ANTHROPIC_WEB_SEARCH_MAX_TOKENS    - cap output tokens (default: 1024)
 *
 * Docs:
 *   https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/web-search-tool
 */

import { getEnvApiKey } from "../compat";
import type {
	AnthropicApiResponse,
	AnthropicSearchResult,
	SearchCitation,
	SearchResponse,
	SearchSource,
} from "../types";
import { SearchProviderError } from "../types";
import { dateToAgeSeconds } from "../utils";
import type { SearchParams } from "./base";
import { SearchProvider } from "./base";
import { isApiKeyAvailable } from "./utils";

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const WEB_SEARCH_TOOL_TYPE = "web_search_20250305";

const DEFAULT_MODEL = "claude-haiku-4-5";
const DEFAULT_MAX_TOKENS = 1024;
const DEFAULT_MAX_USES = 3;
const MAX_USES_HARD_CAP = 10;

/** Find ANTHROPIC_API_KEY from environment. */
export function findApiKey(): string | null {
	return getEnvApiKey("anthropic") ?? null;
}

function clampInt(
	raw: string | undefined,
	min: number,
	max: number,
	fallback: number,
): number {
	if (raw === undefined || raw.trim() === "") return fallback;
	const n = Number(raw);
	if (!Number.isFinite(n)) return fallback;
	return Math.max(min, Math.min(max, Math.trunc(n)));
}

/** Execute Anthropic web search. */
export async function searchAnthropic(params: SearchParams): Promise<SearchResponse> {
	const apiKey = findApiKey();
	if (!apiKey) {
		throw new SearchProviderError(
			"anthropic",
			"ANTHROPIC_API_KEY not found. Set it in environment or .env file.",
		);
	}

	const model = (process.env.ANTHROPIC_WEB_SEARCH_MODEL ?? DEFAULT_MODEL).trim() || DEFAULT_MODEL;
	const maxUses = clampInt(
		process.env.ANTHROPIC_WEB_SEARCH_MAX_USES,
		1,
		MAX_USES_HARD_CAP,
		DEFAULT_MAX_USES,
	);
	const maxTokens =
		params.maxOutputTokens ??
		clampInt(process.env.ANTHROPIC_WEB_SEARCH_MAX_TOKENS, 256, 16384, DEFAULT_MAX_TOKENS);

	const body = {
		model,
		max_tokens: maxTokens,
		system: params.systemPrompt,
		messages: [{ role: "user", content: params.query }],
		tools: [
			{
				type: WEB_SEARCH_TOOL_TYPE,
				name: "web_search",
				max_uses: maxUses,
			},
		],
	};

	const response = await fetch(ANTHROPIC_API_URL, {
		method: "POST",
		signal: params.signal,
		headers: {
			"Content-Type": "application/json",
			"x-api-key": apiKey,
			"anthropic-version": ANTHROPIC_VERSION,
		},
		body: JSON.stringify(body),
	});

	if (!response.ok) {
		const text = await response.text().catch(() => "");
		throw new SearchProviderError(
			"anthropic",
			`Anthropic API error (${response.status}): ${text.slice(0, 500)}`,
			response.status,
		);
	}

	const data = (await response.json()) as AnthropicApiResponse;
	const requestId = response.headers.get("request-id") ?? response.headers.get("x-request-id") ?? undefined;

	const sources: SearchSource[] = [];
	const citations: SearchCitation[] = [];
	const searchQueries: string[] = [];
	const answerParts: string[] = [];
	const seenUrls = new Set<string>();

	for (const block of data.content ?? []) {
		switch (block.type) {
			case "text": {
				if (block.text) answerParts.push(block.text);
				for (const c of block.citations ?? []) {
					citations.push({
						url: c.url,
						title: c.title,
						citedText: c.cited_text,
					});
				}
				break;
			}
			case "server_tool_use": {
				if (block.input?.query) searchQueries.push(block.input.query);
				break;
			}
			case "web_search_tool_result": {
				for (const r of (block.content ?? []) as AnthropicSearchResult[]) {
					if (!r.url || seenUrls.has(r.url)) continue;
					seenUrls.add(r.url);
					sources.push({
						title: r.title || r.url,
						url: r.url,
						publishedDate: r.page_age ?? undefined,
						ageSeconds: dateToAgeSeconds(r.page_age),
					});
				}
				break;
			}
		}
	}

	const limit = params.limit ?? params.numSearchResults;
	const trimmedSources = limit && limit > 0 ? sources.slice(0, limit) : sources;

	return {
		provider: "anthropic",
		model: data.model,
		answer: answerParts.join("\n\n").trim() || undefined,
		sources: trimmedSources,
		citations: citations.length > 0 ? citations : undefined,
		searchQueries: searchQueries.length > 0 ? searchQueries : undefined,
		requestId: data.id ?? requestId,
		usage: {
			inputTokens: data.usage?.input_tokens,
			outputTokens: data.usage?.output_tokens,
			searchRequests: data.usage?.server_tool_use?.web_search_requests,
		},
		authMode: "api-key",
	};
}

/** Search provider for Anthropic's web_search server tool. */
export class AnthropicProvider extends SearchProvider {
	readonly id = "anthropic";
	readonly label = "Anthropic";

	isAvailable() {
		return isApiKeyAvailable(findApiKey);
	}

	search(params: SearchParams): Promise<SearchResponse> {
		return searchAnthropic(params);
	}
}
