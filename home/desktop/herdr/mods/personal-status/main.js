import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, agents, panes, terminals, focused, exec, theme, run, window, keys, props, shared, setShared, layout, appHome } from "herdr";

function find(node, id) {
  if (!node) return null;
  if (node.id === id) return node;
  for (const child of node.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

function fmtUsd(v) {
  if (typeof v !== "number" || Number.isNaN(v)) return null;
  if (v === 0) return "$0.00";
  if (v < 0.01) return `$${v.toFixed(3)}`;
  return `$${v.toFixed(2)}`;
}

function spaceTerminalSet(space, allPanes, allTerms) {
  const set = new Set();
  if (!space) return set;
  const tabIds = new Set((space.tabs ?? []).map((t) => t.id));
  for (const p of allPanes) if (p.terminal && tabIds.has(p.tab)) set.add(p.terminal);
  const localId = space.id.split("/").pop();
  for (const t of allTerms) if (t.state === "live" && t.labels?.["herdr.space"] === localId) set.add(t.address);
  let added = true;
  while (added) {
    added = false;
    for (const t of allTerms) {
      if (t.state === "live" && !set.has(t.address) && t.parent && set.has(t.parent)) {
        set.add(t.address);
        added = true;
      }
    }
  }
  return set;
}

export default class PersonalStatus extends View {
  init(_props, cx) {
    this.busy = false;
    this.lastPoll = 0;
    cx.timer.every(3000, (cx) => this.backgroundSync(cx));
    this.backgroundSync(cx);
  }

  backgroundSync(cx) {
    if (this.busy) return;
    const summary = shared("personalCosts.summary");
    const now = Date.now();
    // If personal-costs panel is open and updating, don't duplicate its work.
    if (summary && now - (summary.updatedAt ?? 0) < 7000) return;
    if (!window().active && summary) return;
    if (now - this.lastPoll < 6000) return;
    this.busy = true;
    this.lastPoll = now;

    const sp = spaces();
    const allPanes = panes();
    const allTerms = terminals();
    const liveTerms = allTerms
      .filter((t) => t.state === "live")
      .map((t) => ({
        address: t.address,
        state: t.state,
        app: t.app ?? null,
        title: t.title ?? "",
        created_ms: t.created_ms ?? 0,
        cwd: t.cwd ?? "",
        program: t.program ? { key: t.program.key ?? "" } : null,
        argv: Array.isArray(t.argv) && t.argv.length ? [t.argv[0]] : [],
        labels: t.labels?.["herdr-preview.session"]
          ? { "herdr-preview.session": t.labels["herdr-preview.session"] }
          : {},
      }));

    cx.spawn(async (cx) => {
      try {
        const script = appHome() + "/mods/personal-costs/cost-query.py";
        const res = await exec("python3", [script, JSON.stringify({ terminals: liveTerms })]);
        if (res.code !== 0) return;
        const parsed = JSON.parse(res.stdout || "{}");
        const costs = parsed.agents ?? {};
        // Only publish if personal-costs hasn't published fresher data meanwhile.
        const latest = shared("personalCosts.summary");
        if (latest && Date.now() - (latest.updatedAt ?? 0) < 3000) return;

        const space = sp.find((s) => s.active) ?? null;
        const f = focused();
        const focusedAgent = agents().find((a) => a.focused)?.address ?? null;
        const selectedAddr = f?.agent || f?.terminal || focusedAgent;
        const sel = selectedAddr ? costs[selectedAddr] : null;
        const inSpace = spaceTerminalSet(space, allPanes, allTerms);
        let spaceCost = 0;
        let hasSpaceCost = false;
        for (const addr of inSpace) {
          const c = costs[addr]?.cost;
          if (typeof c === "number") {
            spaceCost += c;
            hasSpaceCost = true;
          }
        }
        setShared("personalCosts.summary", {
          agentAddr: selectedAddr ?? null,
          agentCost: typeof sel?.cost === "number" ? sel.cost : null,
          agentBilling: sel?.billing ?? null,
          spaceId: space?.id ?? null,
          spaceName: space?.name ?? null,
          spaceCost: hasSpaceCost ? spaceCost : null,
          updatedAt: Date.now(),
        });
        cx.notify();
      } catch {
      } finally {
        this.busy = false;
      }
    });
  }

  hint() {
    const mac = window()?.platform === "macos";
    const mod = {
      cmd: mac ? "⌘" : "Ctrl+",
      ctrl: mac ? "⌃" : "Ctrl+",
      shift: mac ? "⇧" : "Shift+",
      alt: mac ? "⌥" : "Alt+",
      option: mac ? "⌥" : "Alt+",
    };
    const b = keys().find((k) => k.section === "global" && k.action === "app.palette");
    const parts = b && b.keys.endsWith("--") ? [...b.keys.slice(0, -2).split("-"), "-"] : b?.keys.split("-");
    const key = parts && parts.map((p) => mod[p.toLowerCase()] ?? p.toUpperCase()).join("");
    return key ? `${key}  commands` : "commands";
  }

  toggleCosts() {
    const root = layout();
    const panel = find(root, "panel");
    const body = find(root, "panel-body");
    const open = panel && !panel.hidden && body?.active === "costs";
    if (open) {
      run("layout.hide", { id: "panel" });
    } else {
      run("layout.select", { stack: "panel-body", child: "costs" });
      run("layout.show", { id: "panel" });
    }
  }

  costText(space) {
    const summary = shared("personalCosts.summary");
    if (!summary || summary.spaceId !== space?.id) return "Costs";
    const a = summary.agentBilling === "subscription" ? "sub" : fmtUsd(summary.agentCost);
    const s = fmtUsd(summary.spaceCost);
    if (a && s) return `agent ${a} · space ${s}`;
    if (s) return `space ${s}`;
    if (a) return `agent ${a}`;
    return "Costs";
  }

  render() {
    const t = theme();
    const flat = Boolean(props()?.flat);
    const space = spaces().find((s) => s.active);
    const list = agents();
    const needs = list.filter((a) => a.status === "blocked").length;
    const working = list.filter((a) => a.status === "working").length;
    const label = (iconName, text) =>
      h_flex().gap(6).items_center().child(svg(`mods/personal-status/${iconName}.svg`).size(12.5)).child(text);
    return h_flex()
      .size_full()
      .pl(flat ? 13.5 : 14)
      .pr(14)
      .gap(16)
      .items_center()
      .bg(t.chrome)
      .when(!flat, (el) => el.border_t(1).border_color(t.border))
      .text_size(11.5)
      .text_color(t.muted)
      .child(label(space?.machine ? "server" : "monitor", space?.machine ?? "This computer"))
      .when(Boolean(space?.branch), (el) => el.child(label("branch", space.branch)))
      .child(
        h_flex()
          .gap(6)
          .items_center()
          .child(div().size(6).rounded(3).bg(needs > 0 ? t.blocked : working > 0 ? t.working : t.dim))
          .child(`${list.length} agents`)
          .when(working > 0, (el) => el.child(div().text_color(t.dim).child(`· ${working} working`)))
          .when(needs > 0, (el) => el.child(div().text_color(t.blocked).child(`· ${needs} needs you`))),
      )
      .child(div().flex_1())
      .child(
        h_flex()
          .id("status-costs")
          .gap(4)
          .px(6)
          .py(2)
          .rounded(4)
          .items_center()
          .cursor_pointer()
          .text_color(t.muted)
          .hover((s) => s.bg(t.hover).text_color(t.foreground))
          .on_click(() => this.toggleCosts())
          .child(svg("mods/personal-costs/dollar.svg").size(12).text_color(t.accent))
          .child(this.costText(space)),
      )
      .child(
        div()
          .id("palette")
          .cursor_pointer()
          .text_color(t.dim)
          .hover((s) => s.text_color(t.foreground))
          .on_click(() => run("app.palette"))
          .child(this.hint()),
      );
  }
}
