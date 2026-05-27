/**
 * pi extension: `web_fetch` tool — fetch a URL, dispatch to 78 vendored
 * site-specific handlers (arxiv, github, npm, pypi, crates.io, docs.rs,
 * mdn, stackoverflow, hackernews, wikipedia, …) for clean API-backed
 * Markdown rendering, fall back to `pi-rs html2md` for everything else.
 *
 * Forked from omp's `tools/fetch.ts` + `web/scrapers/*`. Site handlers
 * live in `./scrapers/`, omp internal imports are remapped through
 * `./compat/`, and the HTML→Markdown primitive shells out to the
 * `pi-rs html2md` Rust subcommand instead of bundling turndown.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import {
  finalizeOutput,
  loadPage,
  type RenderResult,
  type SpecialHandler,
} from "./scrapers/types";
import { htmlToBasicMarkdown } from "./scrapers/types";

import { handleArtifactHub } from "./scrapers/artifacthub";
import { handleArxiv } from "./scrapers/arxiv";
import { handleAur } from "./scrapers/aur";
import { handleBiorxiv } from "./scrapers/biorxiv";
import { handleBluesky } from "./scrapers/bluesky";
import { handleBrew } from "./scrapers/brew";
import { handleCheatSh } from "./scrapers/cheatsh";
import { handleChocolatey } from "./scrapers/chocolatey";
import { handleChooseALicense } from "./scrapers/choosealicense";
import { handleCisaKev } from "./scrapers/cisa-kev";
import { handleClojars } from "./scrapers/clojars";
import { handleCoinGecko } from "./scrapers/coingecko";
import { handleCratesIo } from "./scrapers/crates-io";
import { handleCrossref } from "./scrapers/crossref";
import { handleDevTo } from "./scrapers/devto";
import { handleDiscogs } from "./scrapers/discogs";
import { handleDiscourse } from "./scrapers/discourse";
import { handleDockerHub } from "./scrapers/dockerhub";
import { handleDocsRs } from "./scrapers/docs-rs";
import { handleFdroid } from "./scrapers/fdroid";
import { handleFirefoxAddons } from "./scrapers/firefox-addons";
import { handleFlathub } from "./scrapers/flathub";
import { handleGitHub } from "./scrapers/github";
import { handleGitHubGist } from "./scrapers/github-gist";
import { handleGitLab } from "./scrapers/gitlab";
import { handleGoPkg } from "./scrapers/go-pkg";
import { handleHackage } from "./scrapers/hackage";
import { handleHackerNews } from "./scrapers/hackernews";
import { handleHex } from "./scrapers/hex";
import { handleHuggingFace } from "./scrapers/huggingface";
import { handleIacr } from "./scrapers/iacr";
import { handleJetBrainsMarketplace } from "./scrapers/jetbrains-marketplace";
import { handleLemmy } from "./scrapers/lemmy";
import { handleLobsters } from "./scrapers/lobsters";
import { handleMastodon } from "./scrapers/mastodon";
import { handleMaven } from "./scrapers/maven";
import { handleMDN } from "./scrapers/mdn";
import { handleMetaCPAN } from "./scrapers/metacpan";
import { handleMusicBrainz } from "./scrapers/musicbrainz";
import { handleNpm } from "./scrapers/npm";
import { handleNuGet } from "./scrapers/nuget";
import { handleNvd } from "./scrapers/nvd";
import { handleOllama } from "./scrapers/ollama";
import { handleOpenVsx } from "./scrapers/open-vsx";
import { handleOpenCorporates } from "./scrapers/opencorporates";
import { handleOpenLibrary } from "./scrapers/openlibrary";
import { handleOrcid } from "./scrapers/orcid";
import { handleOsv } from "./scrapers/osv";
import { handlePackagist } from "./scrapers/packagist";
import { handlePubDev } from "./scrapers/pub-dev";
import { handlePubMed } from "./scrapers/pubmed";
import { handlePyPI } from "./scrapers/pypi";
import { handleRawg } from "./scrapers/rawg";
import { handleReadTheDocs } from "./scrapers/readthedocs";
import { handleReddit } from "./scrapers/reddit";
import { handleRepology } from "./scrapers/repology";
import { handleRfc } from "./scrapers/rfc";
import { handleRubyGems } from "./scrapers/rubygems";
import { handleSearchcode } from "./scrapers/searchcode";
import { handleSecEdgar } from "./scrapers/sec-edgar";
import { handleSemanticScholar } from "./scrapers/semantic-scholar";
import { handleSnapcraft } from "./scrapers/snapcraft";
import { handleSourcegraph } from "./scrapers/sourcegraph";
import { handleSpdx } from "./scrapers/spdx";
import { handleSpotify } from "./scrapers/spotify";
import { handleStackOverflow } from "./scrapers/stackoverflow";
import { handleTerraform } from "./scrapers/terraform";
import { handleTldr } from "./scrapers/tldr";
import { handleTwitter } from "./scrapers/twitter";
import { handleVimeo } from "./scrapers/vimeo";
import { handleVscodeMarketplace } from "./scrapers/vscode-marketplace";
import { handleW3c } from "./scrapers/w3c";
import { handleWikidata } from "./scrapers/wikidata";
import { handleWikipedia } from "./scrapers/wikipedia";
import { handleYouTube } from "./scrapers/youtube";

const HANDLERS: SpecialHandler[] = [
  handleArtifactHub, handleArxiv, handleAur, handleBiorxiv, handleBluesky,
  handleBrew, handleCheatSh, handleChocolatey, handleChooseALicense,
  handleCisaKev, handleClojars, handleCoinGecko, handleCratesIo,
  handleCrossref, handleDevTo, handleDiscogs, handleDiscourse,
  handleDockerHub, handleDocsRs, handleFdroid, handleFirefoxAddons,
  handleFlathub, handleGitHub, handleGitHubGist, handleGitLab, handleGoPkg,
  handleHackage, handleHackerNews, handleHex, handleHuggingFace,
  handleIacr, handleJetBrainsMarketplace, handleLemmy, handleLobsters,
  handleMastodon, handleMaven, handleMDN, handleMetaCPAN, handleMusicBrainz,
  handleNpm, handleNuGet, handleNvd, handleOllama, handleOpenVsx,
  handleOpenCorporates, handleOpenLibrary, handleOrcid, handleOsv,
  handlePackagist, handlePubDev, handlePubMed, handlePyPI, handleRawg,
  handleReadTheDocs, handleReddit, handleRepology, handleRfc, handleRubyGems,
  handleSearchcode, handleSecEdgar, handleSemanticScholar, handleSnapcraft,
  handleSourcegraph, handleSpdx, handleSpotify, handleStackOverflow,
  handleTerraform, handleTldr, handleTwitter, handleVimeo,
  handleVscodeMarketplace, handleW3c, handleWikidata, handleWikipedia,
  handleYouTube,
];

const DEFAULT_TIMEOUT_SEC = 20;
const HARD_MAX_CHARS = 200_000;
const DEFAULT_MAX_CHARS = 50_000;

/** Ensure http(s):// scheme for bare `www.` inputs. */
function normalizeUrl(url: string): string {
  const trimmed = url.trim();
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  if (/^www\./i.test(trimmed)) return `https://${trimmed}`;
  return trimmed;
}

async function dispatch(
  url: string,
  timeoutSec: number,
  signal?: AbortSignal,
): Promise<RenderResult | null> {
  for (const handler of HANDLERS) {
    if (signal?.aborted) return null;
    try {
      const r = await handler(url, timeoutSec, signal);
      if (r) return r;
    } catch {
      // Handler-specific failure (e.g. parsing) shouldn't kill the
      // dispatch chain — fall through to the next handler and ultimately
      // the generic path.
    }
  }
  return null;
}

async function fetchGeneric(
  url: string,
  timeoutSec: number,
  raw: boolean,
  signal?: AbortSignal,
): Promise<RenderResult & { status?: number; fetchFailed?: boolean }> {
  const fetchedAt = new Date().toISOString();
  const page = await loadPage(url, { timeout: timeoutSec, signal });

  const finalUrl = page.finalUrl || url;
  const ct = page.contentType.toLowerCase();
  const notes: string[] = [];

  // Hard fetch failure (DNS, connection refused, timeout): no HTTP
  // status, no content. Don't pretend we got a response — but do surface
  // the underlying cause so the model can react (retry, swap protocol,
  // give up) without a second tool call.
  if (!page.ok && page.status === undefined) {
    const reason = (page as { error?: string }).error ?? "DNS error, connection refused, or timeout";
    return {
      url, finalUrl, contentType: page.contentType || "unknown", method: "failed",
      content: `[Fetch failed: ${reason}]`,
      fetchedAt, truncated: false, notes: [`network fetch failed: ${reason}`],
      status: undefined, fetchFailed: true,
    };
  }

  // Non-2xx with a body: surface the status in notes; still parse the
  // body since some error responses (JSON APIs, GitHub 404s) are useful.
  if (!page.ok && page.status !== undefined) {
    notes.push(`HTTP ${page.status}`);
  }

  // JSON: pretty-print directly.
  if (ct.includes("json")) {
    try {
      const parsed = JSON.parse(page.content);
      const out = finalizeOutput(JSON.stringify(parsed, null, 2));
      return {
        url, finalUrl, contentType: page.contentType, method: "json",
        content: out.content, fetchedAt, truncated: out.truncated, notes,
        status: page.status,
      };
    } catch {
      // fall through to text/raw handling
    }
  }

  // Plain text/markdown: pass through.
  if (
    ct.startsWith("text/plain") ||
    ct.includes("markdown") ||
    ct.includes("text/x-markdown")
  ) {
    const out = finalizeOutput(page.content);
    return {
      url, finalUrl, contentType: page.contentType, method: "text",
      content: out.content, fetchedAt, truncated: out.truncated, notes,
      status: page.status,
    };
  }

  // HTML: convert via pi-rs html2md unless raw was requested.
  if (ct.includes("html") || ct.includes("xhtml")) {
    if (raw) {
      const out = finalizeOutput(page.content);
      return {
        url, finalUrl, contentType: page.contentType, method: "raw-html",
        content: out.content, fetchedAt, truncated: out.truncated, notes,
        status: page.status,
      };
    }
    try {
      const md = await htmlToBasicMarkdown(page.content);
      const out = finalizeOutput(md);
      return {
        url, finalUrl, contentType: page.contentType, method: "html2md",
        content: out.content, fetchedAt, truncated: out.truncated, notes,
        status: page.status,
      };
    } catch (err) {
      notes.push(`html2md failed: ${err instanceof Error ? err.message : String(err)}`);
      const out = finalizeOutput(page.content);
      return {
        url, finalUrl, contentType: page.contentType, method: "raw-html-fallback",
        content: out.content, fetchedAt, truncated: out.truncated, notes,
        status: page.status,
      };
    }
  }

  // Anything else: dump as-is (e.g. xml, plain unknown text).
  const out = finalizeOutput(page.content);
  return {
    url, finalUrl, contentType: page.contentType || "unknown", method: "raw",
    content: out.content, fetchedAt, truncated: out.truncated, notes,
    status: page.status,
  };
}

function truncateToMax(text: string, maxChars: number): { text: string; truncated: boolean } {
  if (text.length <= maxChars) return { text, truncated: false };
  const cut = text.slice(0, maxChars);
  return {
    text: cut + `\n\n[truncated: ${maxChars} of ${text.length} chars shown; pass max_chars up to ${HARD_MAX_CHARS} for more]`,
    truncated: true,
  };
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description:
      "Fetch a URL and return its contents as clean Markdown. Dispatches " +
      "to 78 site-specific handlers (arxiv, github, npm, pypi, crates.io, " +
      "docs.rs, mdn, stackoverflow, hackernews, wikipedia, youtube, …) for " +
      "API-backed renderings; falls back to pi-rs html2md (Rust " +
      "html-to-markdown-rs) for generic HTML. JSON pretty-printed. Plain " +
      "text passed through. Forked from oh-my-pi.",
    parameters: Type.Object({
      url: Type.String({ description: "Absolute URL (http or https). Bare `www.foo` also accepted." }),
      raw: Type.Optional(
        Type.Boolean({
          description:
            "Skip site handlers and HTML→Markdown conversion; return the " +
            "raw response body. Default false.",
        }),
      ),
      timeout_sec: Type.Optional(
        Type.Integer({
          description: "Fetch timeout in seconds (default 20, max 60).",
          minimum: 1,
          maximum: 60,
        }),
      ),
      max_chars: Type.Optional(
        Type.Integer({
          description: `Maximum characters to return (default ${DEFAULT_MAX_CHARS}, hard cap ${HARD_MAX_CHARS}).`,
          minimum: 100,
          maximum: HARD_MAX_CHARS,
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
      const url = normalizeUrl(params.url);
      const timeoutSec = params.timeout_sec ?? DEFAULT_TIMEOUT_SEC;
      const maxChars = Math.min(params.max_chars ?? DEFAULT_MAX_CHARS, HARD_MAX_CHARS);

      let parsed: URL;
      try {
        parsed = new URL(url);
      } catch {
        return {
          content: [{ type: "text", text: `Invalid URL: ${params.url}` }],
          details: { url: params.url, error: "invalid_url" },
        };
      }
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        return {
          content: [{ type: "text", text: `Unsupported protocol: ${parsed.protocol}` }],
          details: { url, error: "bad_protocol" },
        };
      }

      let result: RenderResult;
      try {
        // 1. Try site-specific handlers (unless raw was requested).
        const special = params.raw ? null : await dispatch(url, timeoutSec, signal);
        if (special) {
          result = special;
        } else {
          // 2. Generic path.
          result = await fetchGeneric(url, timeoutSec, params.raw === true, signal);
        }
      } catch (err) {
        // Node's `fetch failed` rolls up DNS errors, connection refused,
        // TLS handshake failures, etc. under one opaque message. The
        // useful cause lives on err.cause; thread it into the user-visible
        // text so a single retry can adapt instead of guessing.
        const baseMsg = err instanceof Error ? err.message : String(err);
        const cause = (err as { cause?: unknown } | null | undefined)?.cause;
        let causeMsg: string | null = null;
        if (cause instanceof Error) {
          const code = (cause as { code?: string }).code;
          causeMsg = code ? `${code}: ${cause.message}` : cause.message;
        } else if (cause !== undefined && cause !== null) {
          causeMsg = String(cause);
        }
        const msg = causeMsg && causeMsg !== baseMsg
          ? `${baseMsg} (${causeMsg})`
          : baseMsg;
        return {
          content: [{ type: "text", text: `Fetch failed: ${msg}` }],
          details: { url, error: msg },
        };
      }

      const { text: bodyText, truncated: maxTruncated } = truncateToMax(result.content, maxChars);
      const status = (result as { status?: number }).status;
      const fetchFailed = (result as { fetchFailed?: boolean }).fetchFailed === true;
      const header = [
        `URL: ${result.url}`,
        `Final URL: ${result.finalUrl}`,
        status !== undefined ? `HTTP Status: ${status}` : null,
        `Content-Type: ${result.contentType}`,
        `Method: ${result.method}`,
        result.notes.length > 0 ? `Notes: ${result.notes.join("; ")}` : null,
        `Fetched: ${result.fetchedAt}`,
      ]
        .filter((s): s is string => s !== null)
        .join("\n");

      const text = `${header}\n\n---\n\n${bodyText}`;

      return {
        content: [{ type: "text", text }],
        details: {
          url: result.url,
          finalUrl: result.finalUrl,
          status,
          contentType: result.contentType,
          method: result.method,
          fetchedAt: result.fetchedAt,
          truncated: result.truncated || maxTruncated,
          notes: result.notes,
          ...(fetchFailed ? { fetchFailed: true } : {}),
        },
      };
    },
  });
}
