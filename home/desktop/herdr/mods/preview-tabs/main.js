import { View, div, svg, image } from "gpui-kit";
import * as gpuiBase from "gpui-base";
import { props, spaces, panes, run, openOverlay, theme, window, shared, layout, settings } from "herdr";

const { h_flex } = gpuiBase;

function find(node, id) {
  if (!node) return null;
  if (node.id === id) return node;
  for (const child of node.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

const clean = (s) => (s ?? "").replace(/^[^\p{L}\p{N}]+/u, "").trim();

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

function tabLabel(tab, lead) {
  if (tab.named && !/^tb\d+$/.test(tab.name)) return tab.name;
  const prog = lead?.program?.name;
  const live = clean(lead?.title);
  const path = /^[~/]|^[A-Za-z]:\\/.test((lead?.title ?? "").replace(/^[^\p{L}\p{N}~/]+/u, ""));
  const telling = live && live !== prog && !path && !live.includes("@") && live.toLowerCase() !== (lead?.program?.key ?? "").toLowerCase();
  return telling ? live : prog ?? "Terminal";
}

export default class Tabs extends View {
  init() {
    this.pressed = null;
    this.scroll = gpuiBase.ScrollHandle?.new?.() ?? null;
    this.panels = JSON.parse(localStorage.getItem("panels") ?? "{}");
  }

  syncPanel(space, panel, body, enabled) {
    if (!space || !panel) return;
    const now = panel.hidden ? null : body?.active ?? null;
    if (space.id !== this.space) {
      const first = this.space === undefined;
      this.space = space.id;
      this.pending = null;
      if (!(first && !(space.id in this.panels))) {
        const stored = this.panels[space.id] ?? null;
        const want = enabled.includes(stored) ? stored : null;
        if (want !== now) {
          this.pending = { want, until: Date.now() + 1000 };
          if (want) {
            run("layout.select", { stack: "panel-body", child: want });
            run("layout.show", { id: "panel" });
          } else {
            run("layout.hide", { id: "panel" });
          }
          return;
        }
      }
    }
    if (this.pending) {
      if (this.pending.want !== now && Date.now() < this.pending.until) return;
      this.pending = null;
    }
    if (this.panels[space.id] === now) return;
    this.panels[space.id] = now;
    localStorage.setItem("panels", JSON.stringify(this.panels));
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    const flat = Boolean(p.flat);
    const space = spaces().find((s) => s.active);
    const shown = space?.tabs ?? [];
    const leads = leadPanes(panes());
    const active = shown.findIndex((tab) => tab.active);
    const selected = shown[active]?.id;
    if (selected !== this.selected || active !== this.selectedIndex) {
      this.selected = selected;
      this.selectedIndex = active;
      if (active >= 0 && this.scroll) this.scroll.scroll_to_item(active);
    }
    const stop = (_e, cx) => cx.stop_propagation();
    const button = (id, label, action) =>
      div()
        .id(id)
        .size(26)
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(6)
        .text_color(t.dim)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_mouse_down("left", stop)
        .on_click(action)
        .child(label);

    const activeFill = flat ? t.raised : (t.surface ?? t.raised);

    const item = (c, i) => {
      const lead = leads.get(c.id);
      const program = lead?.program;
      const name = tabLabel(c, lead);
      // In flat mode, Tab 1 starts flush at x=0 of work (`pl(0)`) with `pl(14)` inside,
      // so the pill's left edge aligns with the workspace boundary and its icon aligns
      // at +14px with Intake, the pane header, the terminal grid, and the status bar.
      const padLeft = flat && i === 0 ? 14 : 10;
      return h_flex()
        .id(`tab-${c.id}`)
        .h(29)
        .pl(padLeft)
        .pr(10)
        .gap(7)
        .rounded(flat ? 6 : 7)
        .items_center()
        .flex_none()
        .text_size(12.5)
        .when(Boolean(this.scroll) && i <= active, (el) =>
          el.on_size_change((_size, cx) => {
            this.scroll.scroll_to_item(active);
            cx.notify();
          }),
        )
        .when(!flat, (el) => el.border(1).border_color(c.active ? t.input : t.chrome))
        .bg(c.active ? activeFill : t.chrome)
        .text_color(c.active ? t.foreground : t.muted)
        .when(c.active, (el) => el.font_medium())
        .cursor_pointer()
        .hover((s) => s.bg(c.active ? activeFill : t.hover).text_color(t.foreground))
        .on_mouse_down("left", (e, cx) => {
          cx.stop_propagation();
          this.pressed = i;
          if (e.click_count === 2) run("tab.rename", { id: c.id });
        })
        .on_mouse_up("left", () => {
          const from = this.pressed;
          this.pressed = null;
          if (from !== null && from !== i) {
            run("tab.move", { id: shown[from].id, index: space.tabs.findIndex((x) => x.id === c.id) + 1 });
          } else {
            run("tab.select", { id: c.id });
          }
        })
        .on_mouse_down("right", (_e, cx) => {
          cx.stop_propagation();
          openOverlay({ mod: "menu", kind: "popup", width: 200, props: { tab: "tab", target: { id: c.id, space: space.id } } });
        })
        .when(Boolean(program?.icon), (el) =>
          el.child(program.tint ? svg(program.icon).size(14).text_color(c.active ? t.foreground : t.muted) : image(program.icon).size(14)),
        )
        .child(div().max_w(190).truncate().child(c.zoomed ? `${name} · zoom` : name))
        .when(c.status === "working", (el) =>
          el.child(svg("mods/preview-tabs/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)),
        )
        .when(c.status === "blocked" || c.status === "done", (el) =>
          el.child(div().size(6.5).rounded(4).bg(t[c.status])),
        )
        .when(c.active, (el) =>
          el.child(
            div()
              .id(`close-${c.id}`)
              .p(1)
              .rounded(4)
              .text_color(t.dim)
              .hover((s) => s.bg(t.hover).text_color(t.foreground))
              .on_mouse_down("left", stop)
              .on_click((_e, cx) => {
                cx.stop_propagation();
                run("tab.close", { id: c.id });
              })
              .child(svg("mods/preview-tabs/close.svg").size(12)),
          ),
        );
    };

    const root = layout();
    const sidebar = find(root, "sidebar");
    const w = window();
    const baseLeft = flat ? 0 : 10;
    const lightsPadding =
      w?.platform === "macos" && w.titlebar === "none" && !w.fullscreen && root?.traffic_lights
        ? Math.max(baseLeft, (root.traffic_lights[0] + 64) / settings().zoom - (sidebar?.hidden ? 0 : sidebar?.size?.px ?? 0))
        : baseLeft;
    const panel = find(root, "panel");
    const body = find(root, "panel-body");
    const enabled = [...new Set(["files", ...(shared("workspace.panels") ?? ["files", "changes"]), "preview", "costs"])];
    this.syncPanel(space, panel, body, enabled);

    const panelButton = (id, label, iconPath) => {
      const on = panel && !panel.hidden && body?.active === id;
      return h_flex()
        .id(`panel-${id}`)
        .h(26)
        .px(8)
        .gap(5)
        .flex_none()
        .items_center()
        .rounded(6)
        .text_size(12)
        .cursor_pointer()
        .when(!flat, (el) => el.border(1).border_color(on ? t.input : t.chrome))
        .bg(on ? activeFill : t.chrome)
        .text_color(on ? t.foreground : t.muted)
        .hover((s) => s.bg(on ? activeFill : t.hover).text_color(t.foreground))
        .on_mouse_down("left", stop)
        .on_click(() => {
          if (on) run("layout.hide", { id: "panel" });
          else {
            run("layout.select", { stack: "panel-body", child: id });
            run("layout.show", { id: "panel" });
          }
        })
        .child(svg(iconPath).size(13.5))
        .child(label);
    };

    return h_flex()
      .size_full()
      .min_w(0)
      .pl(lightsPadding)
      .pr(flat ? 2 : 10)
      .gap(4)
      .items_center()
      .bg(t.chrome)
      .when(!flat, (el) => el.border_b(1).border_color(t.border))
      .on_mouse_up("left", () => {
        this.pressed = null;
      })
      .on_scroll_wheel((e) => {
        if (Math.abs(e.delta.y) >= 1) run(e.delta.y > 0 ? "tab.prev" : "tab.next");
      })
      .child(
        h_flex()
          .id("tab-scroll")
          .flex_1()
          .min_w(0)
          .h_full()
          .items_center()
          .gap(4)
          .overflow_x_scrollbar()
          .when(Boolean(this.scroll), (el) =>
            el.track_scroll(this.scroll).on_size_change((_size, cx) => {
              if (active >= 0) {
                this.scroll.scroll_to_item(active);
                cx.notify();
              }
            }),
          )
          .children(shown.map(item)),
      )
      .child(button("tab-new", "+", () => openOverlay({ mod: "new-menu", kind: "popup", width: 250, height: 512 })))
      .when(enabled.includes("files"), (el) => el.child(panelButton("files", "Files", "mods/preview-tabs/files.svg")))
      .when(enabled.includes("changes"), (el) => el.child(panelButton("changes", "Changes", "mods/preview-tabs/git-compare.svg")))
      .child(panelButton("preview", "Preview", "mods/preview-tabs/file-text.svg"))
      .child(panelButton("costs", "Costs", "mods/personal-costs/dollar.svg"))
      .when(w?.buttons && p.windowControls !== false, (el) =>
        el
          .child(button("minimize", w.platform === "windows" ? svg("mods/tabs/win-min.svg").size(16) : "−", () => run("window.minimize")))
          .child(
            button(
              "maximize",
              w.platform === "windows" ? svg(`mods/tabs/${w.maximized ? "win-restore" : "win-max"}.svg`).size(16) : "□",
              () => run("window.maximize"),
            ),
          )
          .child(
            button(
              "close-window",
              w.platform === "windows" ? svg("mods/tabs/win-close.svg").size(16) : svg("mods/preview-tabs/close.svg").size(13),
              () => run("window.close"),
            ),
          ),
      );
  }
}
