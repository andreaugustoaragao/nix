import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, renameSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

type GroupIdentity = { extension: string; label: string; childPid: number | null; pgid: number | null };
export type CleanupOutcome = GroupIdentity & (
  { ok: true } | { ok: false; error: string }
);
export type ShutdownSummary = {
  kind: "shutdown_summary";
  extension: string;
  reason: string;
  sessionId: string;
  ok: boolean;
  failedGroups: CleanupOutcome[];
  unsettledApplies: number;
};

const liveProcessGroups = new Set<number>();
process.once("exit", () => {
  for (const pgid of liveProcessGroups) {
    try { process.kill(-pgid, "SIGTERM"); } catch { }
  }
});

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isOneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && values.some(candidate => candidate === value);
}

export function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new DOMException("Operation cancelled", "AbortError");
}

export function raceSignal<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise;
  return new Promise<T>((resolve, reject) => {
    const abort = () => { cleanup(); reject(new DOMException("Operation cancelled", "AbortError")); };
    const cleanup = () => signal.removeEventListener("abort", abort);
    signal.addEventListener("abort", abort, { once: true });
    promise.then(value => { cleanup(); resolve(value); }, error => { cleanup(); reject(error); });
    if (signal.aborted) abort();
  });
}

export function combinedSignal(session: AbortSignal, caller?: AbortSignal): AbortSignal {
  return caller ? AbortSignal.any([session, caller]) : session;
}

function appendJson(path: string, record: unknown, rotate: boolean): void {
  try {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    if (rotate) {
      try { if (statSync(path).size >= 1024 * 1024) renameSync(path, path + ".1"); } catch { }
    }
    appendFileSync(path, JSON.stringify(record) + "\n", { flag: "a", mode: 0o600 });
  } catch { }
}

export function recordLifecycle<T extends { kind: string; ok?: boolean }>(record: T, failed = record.ok === false): void {
  const event = { ts: Date.now(), ...record };
  if (process.env.PI_LIFECYCLE_EVENTS_FILE) appendJson(process.env.PI_LIFECYCLE_EVENTS_FILE, event, false);
  if (failed) {
    const state = process.env.XDG_STATE_HOME ?? join(homedir(), ".local", "state");
    appendJson(join(state, "pi", "lifecycle-errors.jsonl"), event, true);
  }
}

function startTicks(pid: number): number | null {
  if (process.platform !== "linux") return null;
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const ticks = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19]);
    return Number.isFinite(ticks) && ticks > 0 ? ticks : null;
  } catch { return null; }
}

function groupAlive(pgid: number): boolean {
  try { process.kill(-pgid, 0); return true; }
  catch (error) {
    return !(error instanceof Error && "code" in error && error.code === "ESRCH");
  }
}

export function spawnManagedGroup(
  extension: string, label: string, command: string, args: readonly string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv } = {},
): { child: ChildProcessWithoutNullStreams; shutdown: () => Promise<CleanupOutcome> } {
  const child = spawn(command, [...args], {
    ...options, detached: process.platform !== "win32", stdio: ["pipe", "pipe", "pipe"],
  });
  const pid = child.pid ?? null;
  const pgid = process.platform !== "win32" ? pid : null;
  const identity: GroupIdentity = { extension, label, childPid: pid, pgid };
  let leaderClosed = false;
  let processError: string | undefined;
  child.once("close", () => { leaderClosed = true; });
  child.once("error", error => { processError = error.message; });
  child.stdin.on("error", () => { });
  if (pgid !== null) liveProcessGroups.add(pgid);
  recordLifecycle({ kind: "group_birth", ...identity, childStartTicks: pid === null ? null : startTicks(pid) });

  let cleanup: Promise<CleanupOutcome> | undefined;
  const settled = () => leaderClosed && (pgid === null || !groupAlive(pgid));
  const waitUntil = async (deadline: number) => {
    while (!settled() && Date.now() < deadline) {
      await new Promise<void>(resolve => setTimeout(resolve, Math.min(10, Math.max(1, deadline - Date.now()))));
    }
  };
  const signal = (name: "SIGTERM" | "SIGKILL") => {
    if (pgid !== null) {
      try { process.kill(-pgid, name); }
      catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) throw error;
      }
    } else if (!leaderClosed) child.kill(name);
  };
  const shutdown = (): Promise<CleanupOutcome> => {
    if (cleanup) return cleanup;
    cleanup = (async (): Promise<CleanupOutcome> => {
      const started = Date.now();
      let outcome: CleanupOutcome;
      try {
        child.stdin.end();
        await waitUntil(started + 250);
        if (!settled()) { signal("SIGTERM"); await waitUntil(started + 1500); }
        if (!settled()) { signal("SIGKILL"); await waitUntil(started + 2000); }
        outcome = settled() ? { ...identity, ok: true } : {
          ...identity, ok: false, error: processError ?? "Process group remains alive after 2000ms cleanup",
        };
      } catch (error) {
        outcome = { ...identity, ok: false, error: error instanceof Error ? error.message : String(error) };
      }
      if (outcome.ok && pgid !== null) liveProcessGroups.delete(pgid);
      recordLifecycle({ kind: "group_settled", ...outcome });
      return outcome;
    })();
    return cleanup;
  };
  return { child, shutdown };
}

export class SessionCleanupTracker {
  private trackedCleanups = new Set<Promise<CleanupOutcome>>();
  private retainedFailures = new Map<Promise<CleanupOutcome>, CleanupOutcome>();
  private extension: string;
  constructor(extension: string) { this.extension = extension; }

  trackRetiring(cleanup: Promise<CleanupOutcome>): void {
    if (this.trackedCleanups.has(cleanup) || this.retainedFailures.has(cleanup)) return;
    this.trackedCleanups.add(cleanup);
    cleanup.then(outcome => {
      this.trackedCleanups.delete(cleanup);
      if (!outcome.ok) this.retainedFailures.set(cleanup, outcome);
    }, error => {
      this.trackedCleanups.delete(cleanup);
      const outcome: CleanupOutcome = {
        extension: this.extension, label: "cleanup-rejection", childPid: null, pgid: null, ok: false,
        error: error instanceof Error ? error.message : String(error),
      };
      this.retainedFailures.set(cleanup, outcome);
      recordLifecycle({ kind: "group_settled", ...outcome });
    });
  }

  async runSessionShutdown(options: {
    reason: string; sessionId: string; activeCleanups: Promise<CleanupOutcome>[];
    drainPromises: Promise<unknown>[]; drainTimeoutMs?: number;
  }): Promise<ShutdownSummary> {
    for (const cleanup of options.activeCleanups) this.trackRetiring(cleanup);
    let unsettledApplies = options.drainPromises.length;
    const drains = options.drainPromises.map(promise => promise.then(
      () => { unsettledApplies--; }, () => { unsettledApplies--; },
    ));
    let timer: ReturnType<typeof setTimeout> | undefined;
    const drain = Promise.race([
      Promise.all(drains),
      new Promise<void>(resolve => { timer = setTimeout(resolve, options.drainTimeoutMs ?? 2000); }),
    ]).finally(() => { if (timer) clearTimeout(timer); });
    await Promise.all([Promise.allSettled([...this.trackedCleanups]), drain]);
    const failedGroups = [...this.retainedFailures.values()];
    const summary: ShutdownSummary = {
      kind: "shutdown_summary", extension: this.extension, reason: options.reason,
      sessionId: options.sessionId, ok: failedGroups.length === 0 && unsettledApplies === 0,
      failedGroups, unsettledApplies,
    };
    recordLifecycle(summary);
    if (!summary.ok) throw new Error(`${this.extension} session cleanup failed: ${failedGroups.length} groups, ${unsettledApplies} unsettled applies`);
    return summary;
  }
}
