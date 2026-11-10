import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { display, PAGE, parseTask, record, runBrowserTask, UUID, validateUrl } from "./cli.ts";
import type { Runner, Task } from "./cli.ts";

const KEY = "browser-companion";
const STATE = "browser-companion.selection.v1";
const ACTIONS = ["pick", "start", "info", "page", "open", "screenshot", "keep", "resume", "finish", "forget", "help"];
const HELP = [
  "/browser — task picker and actions",
  "/browser start — create a managed task",
  "/browser use UUID — explicitly select an existing task",
  "/browser page / open — select or create a named page",
  "/browser screenshot — capture the selected page",
  "/browser keep — screenshot, then protect the task for review",
  "/browser resume — explicitly resume; existing snapshot refs become invalid",
  "/browser finish — confirm completion; only this task enters cleanup retention",
  "/browser forget — hide the companion without changing the task",
  "Selection is not an exclusive lock. Info is registry state, not a live-page health check.",
  "No automatic cleanup, resume, navigation, login, or Orca browser access.",
].join("\n");

interface Selection {
  task: string;
  page: string;
  screenshot?: { path: string; page: string };
}

function selection(value: unknown): Selection | undefined {
  if (value === null) return undefined;
  if (!record(value) || typeof value.task !== "string" || !UUID.test(value.task)
    || typeof value.page !== "string" || !PAGE.test(value.page)) return undefined;
  const result: Selection = { task: value.task, page: value.page };
  if (record(value.screenshot) && typeof value.screenshot.path === "string"
    && value.screenshot.path.startsWith("/") && typeof value.screenshot.page === "string"
    && PAGE.test(value.screenshot.page)) {
    result.screenshot = { path: value.screenshot.path, page: value.screenshot.page };
  }
  return result;
}

/** Injectable runner keeps UI/lifecycle tests independent of real browser profiles. */
export function registerCompanion(pi: ExtensionAPI, run: Runner = runBrowserTask) {
  let selected: Selection | undefined;
  let task: Task | undefined;
  let error: string | undefined;
  let busy = false;
  let disposed = false;
  const controller = new AbortController();

  const widget = (ctx: ExtensionContext) => {
    if (disposed || !ctx.hasUI) return;
    if (!selected) {
      ctx.ui.setWidget(KEY, undefined);
      ctx.ui.setStatus(KEY, undefined);
      return;
    }
    const lines = [
      `Browser · ${task?.profile ?? "unknown profile"} · ${task?.state ?? "unknown state"} · ${display(task?.label ?? selected.task)}`,
      `Task ${selected.task} · page ${display(selected.page)} · ${task ? Object.keys(task.pages).length : "?"} registered page(s)`,
    ];
    if (selected.screenshot) lines.push(`Last capture (${display(selected.screenshot.page)}): ${display(selected.screenshot.path)}`);
    if (error) lines.push(`Warning: ${display(error)}`);
    lines.push(busy ? "Browser command running…" : "/browser — actions · registry state; refresh with /browser info");
    ctx.ui.setWidget(KEY, lines);
    ctx.ui.setStatus(KEY, `Browser: ${task?.profile ?? "?"}/${error ? "warning" : task?.state ?? "?"}`);
  };

  const persist = () => {
    if (!disposed) pi.appendEntry(STATE, selected ?? null);
  };
  const call = (args: string[], input?: unknown) => run(args, input, controller.signal);
  const refresh = async (ctx: ExtensionContext) => {
    if (!selected) return;
    try {
      task = parseTask(await call(["info", selected.task]), selected.task);
      error = Object.hasOwn(task.pages, selected.page) ? undefined : "Selected page is no longer registered. Use /browser page.";
    } catch (cause) {
      task = undefined;
      error = cause instanceof Error ? cause.message : String(cause);
      throw cause;
    } finally { widget(ctx); }
  };
  const adopt = async (id: string, ctx: ExtensionContext) => {
    if (!UUID.test(id)) throw new Error("Use a complete lowercase task UUID.");
    const next = parseTask(await call(["info", id]), id);
    const page = Object.hasOwn(next.pages, "main") ? "main" : Object.keys(next.pages)[0];
    if (!page) throw new Error("Task has no registered pages; no task was selected.");
    selected = { task: next.task, page };
    task = next;
    error = undefined;
    persist();
    widget(ctx);
  };
  const requireTask = async (ctx: ExtensionContext, active = false) => {
    if (!selected) throw new Error("Choose or create a task with /browser first.");
    await refresh(ctx);
    if (!task) throw new Error("Task state is unavailable.");
    if (active && task.state !== "active") throw new Error(`Task is ${task.state}. Explicitly use /browser resume first.`);
    return task;
  };
  const capture = async (ctx: ExtensionContext) => {
    const current = await requireTask(ctx, true);
    if (!selected || !Object.hasOwn(current.pages, selected.page)) throw new Error("Choose a registered page with /browser page.");
    const result = await call(["action", current.task, "--page", selected.page, "--timeout", "30"], { type: "screenshot" });
    if (!record(result) || typeof result.path !== "string" || !result.path.startsWith("/") || result.mime !== "image/png") {
      throw new Error("Screenshot response has no private PNG artifact; task was not kept.");
    }
    selected.screenshot = { path: result.path, page: selected.page };
    persist();
    widget(ctx);
    ctx.ui.notify(`Screenshot: ${display(result.path)}`, "info");
  };

  const start = async (ctx: ExtensionContext) => {
    const profile = await ctx.ui.select("Managed profile", ["development — local apps and tests", "accounts — signed-in services"]);
    if (!profile || !["development — local apps and tests", "accounts — signed-in services"].includes(profile)) return;
    const label = await ctx.ui.input("Task label", "Frontend review");
    if (label === undefined) return;
    if (!label.trim() || label.trim().startsWith("-") || display(label) !== label || label.length > 240) {
      throw new Error("Use a short, nonempty label without control characters or a leading dash.");
    }
    const input = await ctx.ui.input("Initial URL (blank opens about:blank)", "http://localhost:3000");
    if (input === undefined) return;
    const url = validateUrl(input);
    const args = ["start", profile.startsWith("development") ? "development" : "accounts", "--label", label.trim(), "--url", url];
    const created = parseTask(await call(args));
    // Remember the returned UUID before any subsequent operation can fail.
    selected = { task: created.task, page: "main" };
    task = created;
    error = undefined;
    persist();
    widget(ctx);
    ctx.ui.notify(`Created managed task ${created.task}.`, "info");
  };

  const pick = async (ctx: ExtensionContext) => {
    const result = await call(["list"]);
    if (!Array.isArray(result)) throw new Error("browser-task list returned invalid data.");
    const tasks: Task[] = [];
    let skipped = 0;
    for (const item of result) {
      try { tasks.push(parseTask(item)); } catch { skipped++; }
    }
    if (skipped) ctx.ui.notify(`${skipped} unavailable/invalid registry record(s) omitted.`, "warning");
    // Exact UUIDs distinguish duplicate labels; listing never adopts or resumes a task.
    const labels = tasks.map(item => `${display(item.label)} · ${item.profile}/${item.state} · ${item.task}`);
    const choice = await ctx.ui.select("Select a task explicitly (other workflows may use these)", ["Create a new managed task", ...labels]);
    if (choice === "Create a new managed task") await start(ctx);
    else if (choice) {
      const index = labels.indexOf(choice);
      if (index >= 0) await adopt(tasks[index].task, ctx);
    }
  };

  const action = async (name: string, ctx: ExtensionContext) => {
    if (name === "help") { ctx.ui.notify(HELP, "info"); return; }
    if (name === "pick") { await pick(ctx); return; }
    if (name === "start") { await start(ctx); return; }
    if (name === "forget") {
      selected = undefined; task = undefined; error = undefined;
      persist(); widget(ctx);
      return;
    }
    if (name === "screenshot") { await capture(ctx); return; }
    const current = await requireTask(ctx, name === "open" || name === "keep");
    if (!selected) return;
    if (name === "info") {
      ctx.ui.notify(`${display(current.label)}\n${current.task}\n${current.profile}/${current.state}\nRegistered pages: ${Object.keys(current.pages).map(display).join(", ")}\nRegistry only; browser availability is checked by actions.`, "info");
    } else if (name === "page") {
      const page = await ctx.ui.select("Registered page", Object.keys(current.pages));
      if (page && Object.hasOwn(current.pages, page)) {
        selected.page = page; error = undefined;
        persist(); widget(ctx);
      }
    } else if (name === "open") {
      const page = await ctx.ui.input("New page name", "mobile");
      if (page === undefined) return;
      if (!PAGE.test(page) || Object.hasOwn(current.pages, page)) throw new Error("Use a new page name: letters, numbers, underscores, or dashes; no leading dash.");
      const input = await ctx.ui.input("URL (blank opens about:blank)", "http://localhost:3000");
      if (input === undefined) return;
      task = parseTask(await call(["open", current.task, "--page", page, "--url", validateUrl(input)]), current.task);
      selected.page = page;
      persist(); widget(ctx);
    } else if (name === "keep") {
      if (!await ctx.ui.confirm("Keep this task for review?", `${display(current.label)}\n${current.task}\nCapture ${selected.page}, then protect all registered pages indefinitely. No other tasks change.`)) return;
      await capture(ctx); // Failure must stop the transition.
      task = parseTask(await call(["keep", current.task]), current.task);
      widget(ctx);
      ctx.ui.notify("Task kept for review. Explicitly resume before further automation or finishing.", "info");
    } else if (name === "resume") {
      if (!await ctx.ui.confirm("Resume this task?", `${display(current.label)}\n${current.task}\nResume automation and invalidate existing snapshot refs. Capture a fresh snapshot before using refs.`)) return;
      task = parseTask(await call(["resume", current.task]), current.task);
      widget(ctx);
    } else if (name === "finish") {
      if (current.state !== "active") throw new Error(`Task is ${current.state}. Explicitly resume before finishing.`);
      if (!await ctx.ui.confirm("Browser work complete?", `${display(current.label)}\n${current.task}\nOnly this task's registered pages enter one-hour retention, then cleanup may close them. Keep instead if you want review.`)) return;
      task = parseTask(await call(["finish", current.task]), current.task);
      widget(ctx);
    } else {
      throw new Error(`Unknown action: ${display(name)}. Use /browser help.`);
    }
  };

  const restore = async (ctx: ExtensionContext) => {
    selected = undefined; task = undefined; error = undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === STATE) selected = selection(entry.data);
    }
    if (selected) {
      try { await refresh(ctx); } catch { /* Keep UUID visible for explicit recovery. */ }
    } else widget(ctx);
  };
  pi.on("session_start", async (_event, ctx) => { if (ctx.hasUI) await restore(ctx); });
  pi.on("session_tree", async (_event, ctx) => { if (ctx.hasUI) await restore(ctx); });
  pi.on("session_shutdown", (_event, ctx) => {
    if (disposed) return;
    disposed = true;
    controller.abort();
    ctx.ui.setWidget(KEY, undefined);
    ctx.ui.setStatus(KEY, undefined);
    // Ending a Pi session is not permission to keep, finish, or close browser tasks.
  });
  pi.on("agent_settled", async (_event, ctx) => {
    if (!selected || busy || disposed || !ctx.hasUI) return;
    try { await refresh(ctx); } catch { /* Display state errors without changing lifecycle. */ }
  });
  pi.on("tool_result", (event, ctx) => {
    if (event.toolName !== "dev_browser" || event.isError || !selected || busy || disposed
      || !record(event.input) || event.input.task !== selected.task || !record(event.input.action)
      || event.input.action.type !== "screenshot") return;
    if (record(event.details) && event.details.error) return;
    const page = typeof event.input.page === "string" ? event.input.page : "main";
    for (const block of event.content) {
      if (block.type !== "text") continue;
      try {
        const result: unknown = JSON.parse(block.text);
        if (record(result) && typeof result.path === "string" && result.path.startsWith("/") && result.mime === "image/png") {
          selected.screenshot = { page, path: result.path };
          persist(); widget(ctx);
        }
      } catch { /* Not a structured screenshot reply. */ }
    }
  });

  pi.registerCommand("browser", {
    description: "Managed browser-task companion: picker, screenshot, keep, resume, finish",
    getArgumentCompletions: prefix => [...ACTIONS, "use"].filter(name => name.startsWith(prefix))
      .map(name => ({ value: name, label: name })),
    handler: async (args, ctx) => {
      if (!ctx.hasUI) throw new Error("/browser requires interactive Pi or an RPC client with extension UI support.");
      if (busy) { ctx.ui.notify("Another companion command is running.", "warning"); return; }
      if (!ctx.isIdle()) { ctx.ui.notify("Wait for the agent to settle before changing browser-task state.", "warning"); return; }
      busy = true;
      widget(ctx);
      try {
        const parts = args.trim().split(/\s+/).filter(Boolean);
        if (parts[0] === "use") {
          if (parts.length !== 2) throw new Error("Usage: /browser use UUID");
          await adopt(parts[1], ctx);
        } else if (parts.length) {
          if (parts.length !== 1 || !ACTIONS.includes(parts[0])) throw new Error("Use /browser help for supported actions.");
          await action(parts[0], ctx);
        } else {
          if (!selected) await pick(ctx);
          if (!selected) return;
          // One action per invocation keeps cancellation and focus behavior simple.
          await refresh(ctx);
          const choice = await ctx.ui.select(`Browser · ${display(task?.label ?? selected.task)} · ${task?.state ?? "unknown"}`, ACTIONS);
          if (choice && ACTIONS.includes(choice)) await action(choice, ctx);
        }
      } catch (cause) {
        const message = cause instanceof Error ? cause.message : String(cause);
        // A failed action may have protected the task as kept. Never retry it.
        if (selected && !disposed) {
          try { await refresh(ctx); } catch { /* Retain the original operation error. */ }
        }
        error = message;
        if (!disposed) ctx.ui.notify(display(message), "error");
      } finally {
        busy = false;
        widget(ctx);
      }
    },
  });
}

export default function browserCompanion(pi: ExtensionAPI) {
  registerCompanion(pi);
}
