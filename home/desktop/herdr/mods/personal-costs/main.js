import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { spaces, agents, panes, terminals, focused, exec, theme, run, appHome, window, shared, setShared } from "herdr";

const ACTIVE_POLL_MS = 3000;
const IDLE_POLL_MS = 8000;
const CHECK_MS = 1000;

function fmtUsd(v) {
  if (v == null || Number.isNaN(v)) return "—";
  if (v === 0) return "$0.00";
  if (v < 0.01) return `$${v.toFixed(4)}`;
  if (v < 10) return `$${v.toFixed(2)}`;
  return `$${v.toFixed(2)}`;
}

function fmtTokens(n) {
  const num = Number(n || 0);
  if (num >= 1_000_000_000) return `${(num / 1_000_000_000).toFixed(2)}B`;
  if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(2)}M`;
  if (num >= 1_000) return `${(num / 1_000).toFixed(1)}K`;
  return String(num);
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

function termDisplayName(term, tab, progName) {
  const explicit = (term?.labels?.["herdr.name"] || term?.name || term?.labels?.["herdr.auto_name"] || "").trim();
  if (explicit) return explicit;
  if (tab?.named && tab?.name && tab.name !== "chief-of-staff") return tab.name;
  return progName || term?.address || "Agent";
}

function spaceAgents(space, allPanes, allTerms, termByAddr) {
  if (!space) return [];
  const tabById = new Map((space.tabs ?? []).map((t) => [t.id, t]));
  const paneByTerm = new Map(allPanes.filter((p) => p.terminal).map((p) => [p.terminal, p]));
  const inSpace = new Set();

  for (const p of allPanes) {
    if (p.terminal && tabById.has(p.tab)) inSpace.add(p.terminal);
  }
  const localSpaceId = space.id.split("/").pop();
  for (const t of allTerms) {
    if (t.state !== "live") continue;
    if (t.labels?.["herdr.space"] === localSpaceId) inSpace.add(t.address);
  }
  // Include live sub-agents whose ancestor belongs to this space.
  let added = true;
  while (added) {
    added = false;
    for (const t of allTerms) {
      if (t.state === "live" && !inSpace.has(t.address) && t.parent && inSpace.has(t.parent)) {
        inSpace.add(t.address);
        added = true;
      }
    }
  }

  const out = [];
  for (const addr of inSpace) {
    const term = termByAddr.get(addr);
    if (!term || term.state !== "live") continue;
    const pane = paneByTerm.get(addr);
    const tab = pane ? tabById.get(pane.tab) : null;
    out.push({ addr, term, pane, tab });
  }
  return out;
}

export default class PersonalCosts extends View {
  init(_props, cx) {
    this.costs = {};
    this.error = null;
    this.loading = false;
    this.lastSelectedAddr = null;
    this.lastRun = 0;
    this.lastSelectionSig = "";
    this.lastTurnSig = "";

    cx.timer.every(CHECK_MS, (cx) => this.checkRefresh(cx));
    this.refresh(cx, true);
  }

  checkRefresh(cx) {
    const sp = spaces();
    const allPanes = panes();
    const allTerms = terminals();
    const termByAddr = new Map(allTerms.map((t) => [t.address, t]));
    const { space, selectedAddr } = this.resolveSelection(sp, allPanes, termByAddr);

    const selSig = `${space?.id ?? ""}|${selectedAddr ?? ""}`;
    if (selSig !== this.lastSelectionSig) {
      this.lastSelectionSig = selSig;
      this.publishSummary();
    }

    const activeAgents = agents();
    const turnSig = activeAgents.map((a) => `${a.address}:${a.status}:${a.seq}`).join(",");
    const turnChanged = turnSig !== this.lastTurnSig;
    if (turnChanged) this.lastTurnSig = turnSig;

    if (!window().active && !turnChanged) return;

    const now = Date.now();
    const anyWorking = space && activeAgents.some((a) => a.space === space.id && a.status === "working");
    const interval = anyWorking ? ACTIVE_POLL_MS : IDLE_POLL_MS;

    if ((turnChanged && now - this.lastRun >= 1500) || now - this.lastRun >= interval) {
      this.refresh(cx, turnChanged);
    }
  }

  refresh(cx, force = false) {
    const now = Date.now();
    if (this.loading || (!force && now - this.lastRun < 3000)) return;
    this.loading = true;
    this.lastRun = now;
    const allTerms = terminals()
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
        const res = await exec("python3", [script, JSON.stringify({ terminals: allTerms })]);
        if (res.code !== 0) {
          this.error = res.stderr.trim() || "Failed to query costs.";
        } else {
          const parsed = JSON.parse(res.stdout || "{}");
          this.costs = parsed.agents ?? {};
          this.error = null;
          this.publishSummary();
        }
      } catch (e) {
        this.error = String(e?.message || e);
      } finally {
        this.loading = false;
        cx.notify();
      }
    });
  }

  resolveSelection(sp, allPanes, termByAddr) {
    const f = focused();
    const focusedAgent = agents().find((a) => a.focused)?.address ?? null;
    const cand = f?.agent || f?.terminal || focusedAgent;
    if (cand && (this.costs[cand] || termByAddr.get(cand)?.program?.agent || termByAddr.get(cand)?.app)) {
      this.lastSelectedAddr = cand;
    }
    const space = sp.find((s) => s.active) ?? null;
    if (!this.lastSelectedAddr && space) {
      const sa = spaceAgents(space, allPanes, [...termByAddr.values()], termByAddr);
      const first = sa.find((x) => this.costs[x.addr]) ?? sa[0];
      if (first) this.lastSelectedAddr = first.addr;
    }
    return { space, selectedAddr: this.lastSelectedAddr };
  }

  publishSummary() {
    const sp = spaces();
    const allPanes = panes();
    const allTerms = terminals();
    const termByAddr = new Map(allTerms.map((t) => [t.address, t]));
    const { space, selectedAddr } = this.resolveSelection(sp, allPanes, termByAddr);

    let spaceCost = 0;
    let hasSpaceCost = false;
    for (const item of spaceAgents(space, allPanes, allTerms, termByAddr)) {
      const c = this.costs[item.addr]?.cost;
      if (typeof c === "number") {
        spaceCost += c;
        hasSpaceCost = true;
      }
    }

    const sel = selectedAddr ? this.costs[selectedAddr] : null;
    setShared("personalCosts.summary", {
      agentAddr: selectedAddr,
      agentCost: typeof sel?.cost === "number" ? sel.cost : null,
      agentBilling: sel?.billing ?? null,
      spaceId: space?.id ?? null,
      spaceName: space?.name ?? null,
      spaceCost: hasSpaceCost ? spaceCost : null,
      updatedAt: Date.now(),
    });
  }

  statRow(t, label, value, sub) {
    return h_flex()
      .items_center()
      .justify_between()
      .py(3)
      .child(div().text_size(11.5).text_color(t.muted).child(label))
      .child(
        h_flex()
          .gap(8)
          .items_center()
          .child(div().text_size(11.5).text_color(t.foreground).child(value))
          .when(Boolean(sub), (el) => el.child(div().text_size(11).text_color(t.dim).child(sub))),
      );
  }

  render(_cx) {
    const t = theme();
    const sp = spaces();
    const allPanes = panes();
    const allTerms = terminals();
    const termByAddr = new Map(allTerms.map((term) => [term.address, term]));
    const { space, selectedAddr } = this.resolveSelection(sp, allPanes, termByAddr);

    const selTerm = selectedAddr ? termByAddr.get(selectedAddr) : null;
    const selPane = selectedAddr ? allPanes.find((p) => p.terminal === selectedAddr) : null;
    const selTab = selPane ? sp.flatMap((s) => s.tabs ?? []).find((tb) => tb.id === selPane.tab) : null;
    const selData = selectedAddr ? this.costs[selectedAddr] : null;

    const list = spaceAgents(space, allPanes, allTerms, termByAddr)
      .map((item) => ({ ...item, data: this.costs[item.addr] ?? null }))
      .filter((item) => item.data || item.term.program?.agent || item.term.app)
      .sort((a, b) => (b.data?.cost ?? -1) - (a.data?.cost ?? -1));

    let spaceTotal = 0;
    let spaceTokens = 0;
    let apiCount = 0;
    let subCount = 0;
    let unpricedCount = 0;
    for (const item of list) {
      const d = item.data;
      if (!d) continue;
      spaceTokens += d.totalTokens || 0;
      if (typeof d.cost === "number") {
        spaceTotal += d.cost;
        apiCount++;
      } else if (d.billing === "subscription") {
        subCount++;
      } else {
        unpricedCount++;
      }
    }

    const selName = selTerm ? termDisplayName(selTerm, selTab, selTerm.program?.name) : "No agent selected";
    const selPic = selTerm ? icon(selTerm.program, 15, t.foreground) : null;
    const selCostText =
      selData?.billing === "subscription"
        ? "Subscription"
        : typeof selData?.cost === "number"
          ? fmtUsd(selData.cost)
          : selData
            ? "Unpriced"
            : "—";

    const toks = selData?.tokens ?? { input: 0, cache_read: 0, cache_write: 0, output: 0, reasoning: 0 };

    return v_flex()
      .id("personal-costs")
      .size_full()
      .bg(t.surface)
      .p(12)
      .gap(12)
      .overflow_y_scrollbar()
      .child(
        h_flex()
          .items_center()
          .justify_between()
          .child(
            h_flex()
              .gap(6)
              .items_center()
              .child(svg("mods/personal-costs/dollar.svg").size(14).text_color(t.accent))
              .child(div().text_size(13).font_semibold().text_color(t.foreground).child("Session Costs")),
          )
          .child(
            div()
              .text_size(11)
              .text_color(t.dim)
              .child(this.loading ? "Updating…" : "Live"),
          ),
      )
      .when(Boolean(this.error), (el) =>
        el.child(
          div()
            .p(8)
            .rounded(6)
            .bg(t.raised)
            .text_size(11.5)
            .text_color(t.blocked)
            .child(this.error),
        ),
      )
      .child(
        v_flex()
          .p(10)
          .rounded(8)
          .bg(t.raised)
          .border(1)
          .border_color(t.border)
          .gap(8)
          .child(
            h_flex()
              .items_center()
              .justify_between()
              .gap(8)
              .child(div().text_size(11).font_medium().text_color(t.dim).child("SELECTED AGENT"))
              .when(Boolean(selData), (el) =>
                el.child(
                  div()
                    .text_size(11)
                    .text_color(t.dim)
                    .child(`${selData.harness}${selData.model ? ` · ${selData.model}` : ""}`),
                ),
              ),
          )
          .child(
            h_flex()
              .items_center()
              .justify_between()
              .gap(8)
              .child(
                h_flex()
                  .flex_1()
                  .min_w(0)
                  .gap(7)
                  .items_center()
                  .when(Boolean(selPic), (el) => el.child(selPic))
                  .child(div().truncate().text_size(13).font_medium().text_color(t.foreground).child(selName)),
              )
              .child(
                div()
                  .flex_none()
                  .text_size(15)
                  .font_semibold()
                  .text_color(selData?.billing === "subscription" ? t.muted : t.accent)
                  .child(selCostText),
              ),
          )
          .when(selData?.billing === "api" || selData?.billing === "unpriced", (el) =>
            el.child(
              v_flex()
                .pt(4)
                .border_t(1)
                .border_color(t.border)
                .child(this.statRow(t, "Input (uncached)", fmtTokens(toks.input)))
                .child(this.statRow(t, "Cache read", fmtTokens(toks.cache_read)))
                .when(toks.cache_write > 0, (w) => w.child(this.statRow(t, "Cache write", fmtTokens(toks.cache_write))))
                .child(
                  this.statRow(
                    t,
                    "Output + reasoning",
                    fmtTokens((toks.output || 0) + (toks.reasoning || 0)),
                    toks.reasoning > 0 ? `${fmtTokens(toks.reasoning)} reas.` : null,
                  ),
                ),
            ),
          )
          .when(selData?.billing === "subscription", (el) =>
            el.child(
              div()
                .pt(4)
                .border_t(1)
                .border_color(t.border)
                .text_size(11.5)
                .text_color(t.dim)
                .child("Subscription harness — token & USD counts are not exposed locally."),
            ),
          ),
      )
      .child(
        v_flex()
          .p(10)
          .rounded(8)
          .bg(t.raised)
          .border(1)
          .border_color(t.border)
          .gap(8)
          .child(
            h_flex()
              .items_center()
              .justify_between()
              .child(div().text_size(11).font_medium().text_color(t.dim).child(`SPACE · ${(space?.name || "None").toUpperCase()}`))
              .child(div().text_size(11).text_color(t.dim).child(fmtTokens(spaceTokens) + " tok")),
          )
          .child(
            h_flex()
              .items_center()
              .justify_between()
              .child(
                div()
                  .text_size(11.5)
                  .text_color(t.muted)
                  .child(
                    [
                      apiCount ? `${apiCount} API` : null,
                      subCount ? `${subCount} sub` : null,
                      unpricedCount ? `${unpricedCount} unpriced` : null,
                    ]
                      .filter(Boolean)
                      .join(" · ") || "No active agents",
                  ),
              )
              .child(
                div()
                  .text_size(15)
                  .font_semibold()
                  .text_color(t.foreground)
                  .child(apiCount > 0 ? fmtUsd(spaceTotal) : "—"),
              ),
          )
          .when(list.length > 0, (el) =>
            el.child(
              v_flex()
                .pt(4)
                .border_t(1)
                .border_color(t.border)
                .gap(3)
                .children(
                  list.map((item) => {
                    const d = item.data;
                    const pic = icon(item.term.program, 13, t.muted);
                    const name = termDisplayName(item.term, item.tab, item.term.program?.name);
                    const active = item.addr === selectedAddr;
                    const rightText =
                      d?.billing === "subscription"
                        ? "sub"
                        : typeof d?.cost === "number"
                          ? fmtUsd(d.cost)
                          : d
                            ? "unpriced"
                            : "—";
                    return h_flex()
                      .id(`cost-ag-${item.addr}`)
                      .px(6)
                      .py(5)
                      .rounded(6)
                      .gap(7)
                      .items_center()
                      .cursor_pointer()
                      .bg(active ? t.selected : t.raised)
                      .hover((s) => s.bg(t.hover))
                      .on_click(() => {
                        this.lastSelectedAddr = item.addr;
                        if (item.pane) run("pane.focus", { pane: item.pane.pane });
                        else run("terminal.peek", { terminal: item.addr });
                      })
                      .when(Boolean(pic), (x) => x.child(pic))
                      .child(
                        v_flex()
                          .flex_1()
                          .min_w(0)
                          .gap(1)
                          .child(div().truncate().text_size(12).text_color(active ? t.foreground : t.muted).child(name))
                          .when(Boolean(d?.model), (x) =>
                            x.child(div().truncate().text_size(10.5).text_color(t.dim).child(`${d.harness} · ${d.model}`)),
                          ),
                      )
                      .child(
                        v_flex()
                          .flex_none()
                          .items_end()
                          .gap(1)
                          .child(div().text_size(12).font_medium().text_color(active ? t.accent : t.foreground).child(rightText))
                          .when(Boolean(d?.totalTokens), (x) =>
                            x.child(div().text_size(10.5).text_color(t.dim).child(fmtTokens(d.totalTokens))),
                          ),
                      );
                  }),
                ),
            ),
          ),
      );
  }
}
