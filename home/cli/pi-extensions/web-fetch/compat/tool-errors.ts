/**
 * Verbatim port of omp's `packages/coding-agent/src/tools/tool-errors.ts`.
 * pi's runtime understands plain Error subclasses, so these work as-is.
 */

export class ToolError extends Error {
  constructor(
    message: string,
    readonly context?: Record<string, unknown>,
  ) {
    super(message);
    this.name = "ToolError";
  }

  /** Render error for LLM consumption. Override for custom formatting. */
  render(): string {
    return this.message;
  }
}

export class ToolAbortError extends Error {
  static readonly MESSAGE = "Operation aborted";

  constructor(message: string = ToolAbortError.MESSAGE) {
    super(message);
    this.name = "ToolAbortError";
  }
}

export function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) {
    const reason = signal.reason instanceof Error ? signal.reason : undefined;
    throw reason instanceof ToolAbortError ? reason : new ToolAbortError();
  }
}

export function renderError(e: unknown): string {
  if (e instanceof ToolError) return e.render();
  if (e instanceof Error) return e.message;
  return String(e);
}
