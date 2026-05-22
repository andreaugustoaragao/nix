/**
 * Compatibility shim for vendored omp scrapers.
 *
 * Each scraper in `../scrapers/*.ts` was forked from
 * `oh-my-pi/packages/coding-agent/src/web/scrapers/`. The original
 * imports from `@oh-my-pi/pi-utils`, `../../tools/tool-errors`, and
 * `../../utils/markit` are remapped here onto a local surface backed by
 * the Node stdlib and the `pi-rs` binary (`pi-rs html2md`, future `pi-rs
 * markit`).
 *
 * The shim is intentionally compact: only the helpers the scrapers
 * actually call are implemented, and each one is a direct re-export from
 * the appropriate sub-module. Keeps the diff against upstream omp small.
 */

export {
  $env,
  ensureTool,
  formatBytes,
  formatNumber,
  getAgentDir,
  globByPrefix,
  isEnoent,
  isRecord,
  parseFrontmatter,
  ptree,
  settings,
  Snowflake,
  tryParseJson,
} from "./pi-utils";

export { logger } from "./pi-utils";

export { throwIfAborted, ToolAbortError, ToolError } from "./tool-errors";

export { convertBufferWithMarkit, convertWithMarkit } from "./markit";

export { htmlToMarkdown } from "./html2md";
