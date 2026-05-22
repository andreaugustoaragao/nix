/**
 * `markit` is omp's binary that converts PDF/DOCX/XLSX/PPTX/RTF/EPUB into
 * Markdown. We don't bundle it (yet). Three scrapers (arxiv, biorxiv,
 * iacr) call this for full-text PDF extraction. They all handle the
 * `ok: false` path gracefully — the user still gets the metadata block
 * (title/authors/abstract/categories) sourced from the site's API,
 * just without the PDF body.
 *
 * Future: add a `pi-rs markit` subcommand wrapping a Rust PDF→Markdown
 * crate (e.g. `pdf-extract` + custom layout heuristics) and replace this
 * stub. For now the contract is "always reports unavailable."
 */

import { Buffer } from "node:buffer";

/**
 * Markit result shape matches omp's actual return type:
 * `{ content: string; ok: boolean; error?: string }`. When the binary is
 * unavailable we return `ok: false` and an empty content; callers
 * (arxiv, biorxiv, iacr) check `ok` and degrade gracefully — the user
 * still gets the metadata block sourced from the site's API.
 */
export interface MarkitResult {
  ok: boolean;
  content: string;
  error?: string;
}

const UNAVAILABLE: MarkitResult = {
  ok: false,
  content: "",
  error: "markit binary not available in this pi build",
};

/**
 * omp signature: `(buffer, hint, signal?)`. No `timeout` arg — the
 * timeout is folded into the signal by the caller via
 * `ptree.combineSignals(signal, timeoutMs)`.
 */
export async function convertBufferWithMarkit(
  _buffer: Uint8Array | Buffer,
  _hint: string,
  _signal?: AbortSignal,
): Promise<MarkitResult> {
  return UNAVAILABLE;
}

/** Alias used by `scrapers/utils.ts`. Same behavior. */
export const convertWithMarkit = convertBufferWithMarkit;
