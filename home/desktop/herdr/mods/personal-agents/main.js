// Agents sidebar with one-click Active focus filter and automatic Quiet folding
// for stale idle sessions (>2h), keeping urgent/working/pinned work front and center.

import { View, div, image, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, panes, focused, spaces, run, theme, shared, setShared, setAgentOrder, openOverlay, closeOverlay, props, window, layout } from "herdr";

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

function toggleSidebar() {
  const width = find(layout(), "sidebar")?.size?.px;
  if (!narrow()) setShared("sidebar.width", width);
  setShared("sidebar.collapsed", !narrow());
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 268) : window()?.platform === "macos" ? 76 : 44 });
}

const clean = (s) => (s ?? "").replace(/^[^\p{L}\p{N}]+/u, "").trim();
const STALE_MS = 2 * 3600 * 1000;

function leadPanes(all) {
  const leads = new Map();
  for (const p of all) {
    if (!p.terminal) continue;
    const current = leads.get(p.tab);
    if (!current || (!current.program?.agent && (p.program?.agent || (!current.focused && p.focused)))) {
      leads.set(p.tab, p);
    }
  }
  return leads;
}

function title(tab, l) {
  const prog = l?.program?.name;
  const live = clean(l?.title);
  const path = /^[~/]|^[A-Za-z]:\\/.test((l?.title ?? "").replace(/^[^\p{L}\p{N}~/]+/u, ""));
  const telling = live && live !== prog && !path && !live.includes("@") && live.toLowerCase() !== l?.program?.key;
  return (tab.name === prog || !tab.named) && telling ? live : tab.name;
}

const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };
const kidStatus = (k, listed) => {
  const s = listed.get(k.address) ?? k.status;
  return s === "error" ? "blocked" : s === "done" ? "idle" : s;
};
const SORTS = [
  { id: "priority", label: "Priority", icon: "clock" },
  { id: "grouped", label: "Grouped by space", icon: "layers" },
];
const sortOf = () => SORTS.find((s) => s.id === shared("agents.sort")) ?? SORTS[0];
const SECTION = { 4: "Needs you", 3: "Done", 2: "Working", 1: "Recent idle" };
const SECTION_STATUS = { 4: "blocked", 3: "done", 2: "working" };

function duration(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 1) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

export default class PersonalAgents extends View {
  init(_props, cx) {
    if (props()?.sortMenu) return;
    // Quiet (stale >2h idle) starts folded so dense multi-day sessions stay tucked away.
    this.folded = new Set(["quiet-idle"]);
    this.changed = JSON.parse(localStorage.getItem("changed") ?? "{}");
    this.pendingPins = JSON.parse(localStorage.getItem("pins") ?? "[]");
    if (!this.pendingPins.length) localStorage.removeItem("pins");
    this.migratingPins = new Set();
    cx.timer.every(30000, (cx) => cx.notify());
  }

  track(list, now) {
    let dirty = false;
    for (const a of list) {
      const s = a.status === "done" ? "idle" : a.status;
      if (this.changed[a.address]?.s === s) continue;
      this.changed[a.address] = { s, at: now };
      dirty = true;
    }
    if (!dirty) return;
    const listed = new Set(list.map((a) => a.address));
    for (const [k, c] of Object.entries(this.changed)) {
      if (!listed.has(k) && now - c.at > 30 * 86400000) delete this.changed[k];
    }
    localStorage.setItem("changed", JSON.stringify(this.changed));
  }

  migratePins(all) {
    const listed = new Map(all.filter((t) => t.state === "live").map((t) => [t.address, t]));
    const pending = this.pendingPins.filter((address) => {
      const terminal = listed.get(address);
      if (!terminal) return true;
      if (terminal.labels?.["herdr.pinned"]) return false;
      if (!this.migratingPins.has(address)) {
        this.migratingPins.add(address);
        run("terminal.pin", { terminal: address, pinned: true });
      }
      return true;
    });
    if (pending.length === this.pendingPins.length) return;
    this.pendingPins = pending;
    if (pending.length) localStorage.setItem("pins", JSON.stringify(pending));
    else localStorage.removeItem("pins");
  }

  since(a) {
    return this.changed[a.address]?.at ?? 0;
  }

  rank(a) {
    return RANK[a.status] ?? 0;
  }

  sortMenu(t) {
    const on = sortOf().id;
    return v_flex()
      .w_full()
      .p(5)
      .bg(t.popover)
      .text_size(12.8)
      .child(div().px(8).pt(4).pb(6).text_size(11).text_color(t.dim).child("Sort agents"))
      .children(
        SORTS.map((s) =>
          h_flex()
            .id(`sort-${s.id}`)
            .h(31)
            .px(8)
            .gap(9)
            .rounded(7)
            .items_center()
            .cursor_pointer()
            .text_color(t.foreground)
            .hover((el) => el.bg(t.hover))
            .on_click(() => {
              setShared("agents.sort", s.id);
              closeOverlay(props().overlay);
            })
            .child(svg(`mods/personal-agents/${s.icon}.svg`).size(14).flex_none().text_color(t.muted))
            .child(div().flex_1().child(s.label))
            .when(s.id === on, (el) => el.child(svg("mods/personal-agents/check.svg").size(14).flex_none().text_color(t.accent))),
        ),
      );
  }

  peek(addr) {
    run("terminal.peek", { terminal: addr });
  }

  tree(all, addr, lead = []) {
    const kids = all.filter((k) => k.parent === addr && k.state === "live");
    return kids.flatMap((k, i) => {
      const last = i === kids.length - 1;
      return [
        { t: k, lines: [...lead, last ? "└" : "├"] },
        ...this.tree(all, k.address, [...lead, last ? "" : "│"]),
      ];
    });
  }

  subRow(t, s, shown, compact) {
    const k = s.t;
    const st = kidStatus(k, this.listed);
    const pic = icon(k.program, 14, t.foreground);
    const on = k.address === shown;
    return h_flex()
      .id(`sub-${k.address}`)
      .pl(39)
      .pr(8)
      .rounded(7)
      .h(26)
      .flex_none()
      .gap(0)
      .items_center()
      .text_size(12.2)
      .cursor_pointer()
      .when(on, (el) => el.bg(t.raised))
      .hover((el) => el.bg(t.hover))
      .on_click(() => (this.listed.has(k.address) ? run("pane.focus", { terminal: k.address }) : this.peek(k.address)))
      .children(
        s.lines.map((l) =>
          div()
            .self_start()
            .mt(-4)
            .w(9)
            .h(17)
            .mr(4)
            .flex_none()
            .when(Boolean(l), (el) => el.border_l(1.5).border_color(t.input))
            .when(l === "└" || l === "├", (el) => el.border_b(1.5).rounded_bl(6)),
        ),
      )
      .when(Boolean(pic), (el) => el.child(div().mr(8).child(pic)))
      .child(div().flex_1().truncate().text_color(on ? t.foreground : t.muted).child(k.name || k.template || k.program?.name || k.address))
      .child(this.status(t, { status: st }, compact));
  }

  status(t, a, compact = false) {
    const color = t[a.status] ?? t.dim;
    if (a.status === "working") return svg("mods/personal-agents/spinner.svg").size(12).mx(1).flex_none().text_color(t.working).spin(900);
    if (a.status === "blocked" && compact) {
      return div()
        .size(14)
        .flex_none()
        .rounded(4)
        .bg(t.blocked + "26")
        .text_size(10.5)
        .font_bold()
        .text_color(t.blocked)
        .flex()
        .items_center()
        .justify_center()
        .child("!");
    }
    if (a.status === "blocked") {
      return div()
        .flex_none()
        .px(6)
        .h(18)
        .rounded(5)
        .bg(t.blocked + "26")
        .text_size(10.5)
        .font_semibold()
        .text_color(t.blocked)
        .flex()
        .items_center()
        .child("Needs you");
    }
    if (a.status === "idle") return div().size(6.5).mx(3).flex_none().rounded(4).border(1.5).border_color(t.idle ?? t.dim);
    return div().size(7).mx(3).flex_none().rounded(4).bg(a.status === "done" ? color : t.dim + "00");
  }

  render() {
    const t = theme();
    if (props()?.sortMenu) return this.sortMenu(t);
    const collapsed = narrow();
    const sort = sortOf();
    const activeOnly = Boolean(shared("agents.activeOnly"));
    let list = agents();
    this.listed = new Map(list.map((a) => [a.address, a.status]));
    const all = terminals();
    this.migratePins(all);
    const shown = focused()?.agent;
    const now = Date.now();
    this.track(list, now);

    const nested = new Set(collapsed ? [] : list.flatMap((a) => this.tree(all, a.address).map((s) => s.t.address)));
    list = list.filter((a) => a.pinned || !nested.has(a.address));

    const tabCounts = new Map();
    for (const a of list) tabCounts.set(a.tab, (tabCounts.get(a.tab) ?? 0) + 1);
    const byPriority = sort.id === "priority";
    const urgency = new Map(
      list.map((a) => [a.address, Math.max(this.rank(a), ...this.tree(all, a.address).map((s) => RANK[kidStatus(s.t, this.listed)] ?? 0))]),
    );
    const rankOf = (a) => urgency.get(a.address) || RANK.idle;
    if (byPriority) list = [...list].sort((x, y) => rankOf(y) - rankOf(x) || this.since(y) - this.since(x) || y.seq - x.seq);

    const pinned = list.filter((a) => a.pinned);
    const unpinned = list.filter((a) => !a.pinned);
    const orderedAll = [...pinned, ...unpinned];
    setAgentOrder(orderedAll.map((a) => a.address));

    const isQuietIdle = (a) => rankOf(a) === RANK.idle && !a.focused && Boolean(this.since(a)) && now - this.since(a) >= STALE_MS;
    const hiddenIdleCount = activeOnly ? unpinned.filter((a) => rankOf(a) === RANK.idle && !a.focused).length : 0;
    const visibleRest = activeOnly ? unpinned.filter((a) => rankOf(a) > RANK.idle || a.focused) : unpinned;

    const withKids = (a, i) => {
      const subs = collapsed ? [] : this.tree(all, a.address);
      const r = row(a, i, subs);
      if (this.folded.has(a.address)) return [r];
      return [r, ...subs.map((s) => this.subRow(t, s, shown, byPriority))];
    };

    const fold = (a, subs) => {
      const sts = subs.map((s) => kidStatus(s.t, this.listed));
      const top = sts.reduce((m, s) => ((RANK[s] ?? 0) > (RANK[m] ?? 0) ? s : m), null);
      const open = !this.folded.has(a.address);
      return div()
        .id(`fold-${a.address}`)
        .h(18)
        .px(3)
        .gap(3)
        .flex()
        .items_center()
        .rounded(4)
        .text_size(11)
        .text_color(open ? t.dim : t[top] ?? t.dim)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click((_e, cx) => {
          cx.stop_propagation();
          open ? this.folded.add(a.address) : this.folded.delete(a.address);
          cx.notify();
        })
        .child(svg(`mods/personal-agents/chevron-${open ? "down" : "right"}.svg`).size(11).flex_none())
        .when(!open, (el) => el.child(String(subs.length)));
    };

    const leads = leadPanes(panes());
    const termByAddr = new Map(all.map((t) => [t.address, t]));
    const tabs = new Map(spaces().flatMap((s) => s.tabs).map((tab) => [tab.id, tab]));
    const labels = new Map(
      orderedAll.map((a) => {
        const term = termByAddr.get(a.address);
        const termName = clean(term?.labels?.["herdr.name"] || term?.name || term?.labels?.["herdr.auto_name"] || "");
        const tab = tabs.get(a.tab);
        const many = tabCounts.get(a.tab) > 1;
        if (termName && (many || !tab?.named)) return [a.address, termName];
        return [a.address, tab ? title(many ? { ...tab, named: false } : tab, many ? a : leads.get(a.tab)) : a.title || a.program?.name || ""];
      }),
    );
    const label = (a) => labels.get(a.address);
    const detail = new Map(orderedAll.map((a) => [a.address, /^\d+$/.test(label(a)) ? null : label(a)]));
    const seen = {};
    for (const a of orderedAll) {
      const k = `${a.space_name}\u0000${detail.get(a.address) ?? ""}`;
      seen[k] = (seen[k] ?? 0) + 1;
    }
    for (const a of orderedAll) {
      if (detail.get(a.address) == null && seen[`${a.space_name}\u0000`] > 1) detail.set(a.address, label(a));
    }

    const row = (a, i, subs = []) => {
      const idle = rankOf(a) === RANK.idle && !a.focused;
      const pic = icon(a.program, 15, idle ? t.muted : t.foreground);
      const more = detail.get(a.address);
      const machine = a.address.includes("/") ? a.address.split("/")[0] : null;
      if (collapsed) {
        return h_flex()
          .id(`ag-${a.address}`)
          .h(26)
          .px(8)
          .flex_none()
          .items_center()
          .gap(4)
          .cursor_pointer()
          .hover((s) => s.bg(t.hover))
          .on_click(() => run("pane.focus", { pane: a.pane }))
          .child(div().flex_1().min_w(0).whitespace_nowrap().text_right().text_color(t.muted).child(String(i + 1)))
          .child(h_flex().w(14).flex_none().items_center().justify_center().child(this.status(t, a, true)));
      }
      const when = this.since(a);
      const isPinned = a.pinned;
      const pin = div()
        .id(`pin-${a.address}`)
        .flex_none()
        .p(2)
        .rounded(4)
        .text_color(t.dim)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .tooltip(isPinned ? "Unpin" : "Pin to the top")
        .on_click((_e, cx) => {
          cx.stop_propagation();
          run("terminal.pin", { terminal: a.address, pinned: !isPinned });
          this.hovered = null;
          cx.notify();
        })
        .child(svg(`mods/personal-agents/${isPinned ? "pin-off" : "pin"}.svg`).size(13));
      const full = byPriority || isPinned || isQuietIdle(a);
      const name = full ? a.space_name || label(a) : more ?? (/^\d+$/.test(label(a)) ? a.program?.name || label(a) : label(a));
      return h_flex()
        .id(`ag-${a.address}`)
        .relative()
        .px(8)
        .h(29)
        .flex_none()
        .rounded(7)
        .items_center()
        .gap(8)
        .when(a.focused, (el) =>
          el
            .bg(t.selected)
            .child(div().absolute().left(2).top(6).bottom(6).w(2.5).rounded(2).bg(t.accent)),
        )
        .cursor_pointer()
        .when(!a.focused, (el) => el.hover((s) => s.bg(t.hover)))
        .on_hover((on, cx) => {
          if (on) this.hovered = a.address;
          else if (this.hovered === a.address) this.hovered = null;
          cx.notify();
        })
        .on_click(() => run("pane.focus", { pane: a.pane }))
        .when(Boolean(pic), (el) =>
          el.child(
            div()
              .id(`agent-fold-${a.address}`)
              .when(subs.length > 0, (sub) =>
                sub.on_click((_e, cx) => {
                  cx.stop_propagation();
                  this.folded.has(a.address) ? this.folded.delete(a.address) : this.folded.add(a.address);
                  cx.notify();
                }),
              )
              .child(pic),
          ),
        )
        .child(
          h_flex()
            .flex_1()
            .min_w(0)
            .gap(5)
            .items_center()
            .child(div().min_w(0).max_w(full && more ? 120 : 195).truncate().text_color(idle ? t.muted : t.foreground).child(name))
            .when(full && Boolean(more), (el) => el.child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(`· ${more}`))),
        )
        .when(Boolean(machine), (el) => el.child(div().text_size(10).text_color(t.dim).child(machine)))
        .when(subs.length > 0, (el) => el.child(fold(a, subs)))
        .when(this.hovered === a.address, (el) => el.child(pin))
        .when(this.hovered !== a.address && Boolean(when), (el) =>
          el.child(div().flex_none().text_size(11).text_color(t.dim).child(duration(now - when))),
        )
        .child(this.status(t, a, byPriority && !isPinned));
    };

    const freshRest = activeOnly ? visibleRest : visibleRest.filter((a) => !isQuietIdle(a));
    const quietRest = activeOnly ? [] : visibleRest.filter(isQuietIdle);

    const groups = pinned.length ? [{ id: "pinned", label: "Pinned", status: null, members: pinned }] : [];
    for (const a of freshRest) {
      const r = rankOf(a);
      const id = byPriority ? `sec-${r}` : `sp-${a.space}`;
      if (groups.at(-1)?.id === id) groups.at(-1).members.push(a);
      else groups.push({ id, label: byPriority ? SECTION[r] : a.space_name || "", status: byPriority ? SECTION_STATUS[r] : null, members: [a] });
    }
    if (quietRest.length) {
      groups.push({ id: "quiet-idle", label: "Quiet", status: null, members: quietRest, countAlways: true });
    }

    const header = (g) => {
      const open = !this.folded.has(g.id);
      const top = g.members.reduce((m, a) => ((RANK[a.status] ?? 0) > (RANK[m] ?? 0) ? a.status : m), null);
      return h_flex()
        .id(g.id)
        .px(8)
        .pt(6)
        .h(28)
        .flex_none()
        .gap(6)
        .items_center()
        .text_size(11)
        .font_medium()
        .cursor_pointer()
        .hover((s) => s.text_color(t.foreground))
        .on_click((_e, cx) => {
          open ? this.folded.add(g.id) : this.folded.delete(g.id);
          cx.notify();
        })
        .child(div().truncate().text_color(t[g.status] ?? t.dim).child(g.label))
        .when(byPriority || !open || Boolean(g.countAlways), (el) => el.child(div().text_color(t.dim).child(String(g.members.length))))
        .child(div().flex_1())
        .when(!open, (el) =>
          el
            .when(!byPriority && top && top !== "idle", (sub) => sub.child(this.status(t, { status: top }, true)))
            .child(svg("mods/personal-agents/chevron-right.svg").size(11).flex_none().text_color(t.dim)),
        );
    };

    const rows = collapsed
      ? orderedAll.flatMap(withKids)
      : groups.flatMap((g) => [header(g), ...(this.folded.has(g.id) ? [] : g.members.flatMap(withKids))]);

    const activeCount = orderedAll.filter((a) => rankOf(a) > RANK.idle).length;

    return v_flex()
      .size_full()
      .min_h(0)
      .bg(t.chrome)
      .text_size(13)
      .when(!collapsed, (el) =>
        el.child(
          h_flex()
            .px(14)
            .h(36)
            .pt(6)
            .pb(2)
            .flex_none()
            .items_center()
            .gap(6)
            .child(div().text_size(11.5).font_medium().text_color(t.dim).child("Agents"))
            .when(activeCount > 0, (sub) =>
              sub.child(
                div()
                  .px(5)
                  .h(16)
                  .rounded(4)
                  .flex()
                  .items_center()
                  .bg(t.raised)
                  .text_size(10.5)
                  .text_color(t.muted)
                  .child(String(activeCount)),
              ),
            )
            .child(div().flex_1())
            .child(
              div()
                .id("ag-focus-filter")
                .px(7)
                .h(20)
                .rounded(5)
                .flex()
                .items_center()
                .cursor_pointer()
                .text_size(11)
                .bg(activeOnly ? t.selected : Boolean(props()?.flat) ? t.raised : t.chrome)
                .when(!props()?.flat, (b) => b.border(1).border_color(activeOnly ? t.accent : t.border))
                .text_color(activeOnly ? t.accent : t.dim)
                .hover((s) => s.bg(t.hover).text_color(t.foreground))
                .tooltip(activeOnly ? "Showing active and pinned agents. Click to show idle too." : "Hide idle agents")
                .on_click(() => setShared("agents.activeOnly", !activeOnly))
                .child("Focus"),
            )
            .child(
              div()
                .id("ag-sort")
                .size(22)
                .rounded(5)
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .text_color(t.dim)
                .hover((s) => s.bg(t.hover).text_color(t.foreground))
                .on_click(() => openOverlay({ mod: "personal-agents", kind: "popup", width: 200, height: 140, props: { sortMenu: true } }))
                .tooltip(`Sort agents: ${sort.label}`)
                .child(svg(`mods/personal-agents/${sort.icon}.svg`).size(13.5)),
            ),
        ),
      )
      .when(orderedAll.length === 0 && !collapsed, (el) =>
        el.child(
          div()
            .px(14)
            .py(8)
            .text_size(12)
            .text_color(t.dim)
            .child("No agent status yet. Agents appear here once they report status."),
        ),
      )
      .when(orderedAll.length > 0 && rows.length === 0 && activeOnly && !collapsed, (el) =>
        el.child(
          h_flex()
            .id("ag-all-quiet")
            .mx(8)
            .px(10)
            .h(30)
            .rounded(7)
            .items_center()
            .justify_between()
            .text_size(12)
            .text_color(t.dim)
            .cursor_pointer()
            .hover((s) => s.bg(t.hover).text_color(t.foreground))
            .on_click(() => setShared("agents.activeOnly", false))
            .child("All quiet right now")
            .child(div().text_size(11).text_color(t.muted).child(`${hiddenIdleCount} idle`)),
        ),
      )
      .child(v_flex().id("ag-list").flex_1().min_h(0).px(collapsed ? 0 : 6).pb(8).gap(1).overflow_y_scrollbar().children(rows))
      .when(activeOnly && rows.length > 0 && hiddenIdleCount > 0 && !collapsed, (el) =>
        el.child(
          h_flex()
            .id("ag-show-idle")
            .h(26)
            .px(14)
            .flex_none()
            .items_center()
            .justify_between()
            .text_size(11)
            .text_color(t.dim)
            .cursor_pointer()
            .hover((s) => s.text_color(t.foreground))
            .on_click(() => setShared("agents.activeOnly", false))
            .child(`${hiddenIdleCount} idle hidden`)
            .child("Show all"),
        ),
      )
      .when(collapsed, (el) =>
        el.child(
          h_flex()
            .h(28)
            .items_center()
            .justify_center()
            .child(
              div()
                .id("collapse")
                .size(26)
                .rounded(6)
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .text_color(t.dim)
                .hover((s) => s.bg(t.hover).text_color(t.foreground))
                .tooltip("Expand sidebar")
                .on_click(toggleSidebar)
                .child(svg("mods/personal-agents/chevron-right.svg").size(13)),
            ),
        ),
      );
  }
}
