import { View, div, image, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { theme, run, props, window, shared, setShared, updates, layout } from "herdr";

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
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 272) : window()?.platform === "macos" ? 76 : 44 });
}

export default class WorkspaceChrome extends View {
  button(id, label, action, tip) {
    const t = theme();
    return div()
      .id(id)
      .size(26)
      .flex_none()
      .flex()
      .items_center()
      .justify_center()
      .rounded(6)
      .cursor_pointer()
      .text_color(t.muted)
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .when(Boolean(tip), (el) => el.tooltip(tip))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click(action)
      .child(label);
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    const flat = Boolean(p.flat);
    const collapsed = narrow();
    if (p.settings) {
      return h_flex()
        .size_full()
        .items_center()
        .justify_center()
        .bg(t.chrome)
        .when(!flat, (el) => el.border_b(1).border_color(t.border))
        .child(
          this.button("settings", svg("mods/personal-chrome/settings.svg").size(15.5), () => run("app.settings"), "Settings (Ctrl+,)")
            .relative()
            .accessibility_label("Settings")
            .when(Boolean(updates().app.ready), (el) =>
              el.child(div().absolute().top(2).right(2).size(6).rounded_full().bg(t.accent)),
            ),
        );
    }
    if (p.footer) {
      const row = (id, icon, label, dim, action) =>
        h_flex()
          .id(id)
          .h(flat ? 24 : 28)
          .px(8)
          .gap(8)
          .items_center()
          .rounded(6)
          .text_color(dim ? t.dim : t.muted)
          .hover((s) => s.bg(t.hover).text_color(t.foreground))
          .cursor_pointer()
          .on_click(action)
          .child(svg(`mods/personal-chrome/${icon}.svg`).size(flat ? 12.5 : 13.5))
          .when(!collapsed, (el) => el.child(label));
      return v_flex()
        .size_full()
        .bg(t.chrome)
        .when(!flat, (el) => el.border_t(1).border_color(t.border))
        .px(6)
        .justify_center()
        .text_size(flat ? 11.5 : 12.5)
        .child(row("machine", "plus", "Add machine", true, () => run("mod.open", { name: "machine-add" })));
    }
    return h_flex()
      .size_full()
      .bg(t.chrome)
      .when(!flat, (el) => el.border_b(1).border_color(t.border))
      .pl(collapsed ? 6 : 14)
      .pr(10)
      .gap(4)
      .items_center()
      .text_size(13.5)
      .when(window()?.platform === "macos" && !window()?.fullscreen && !collapsed, (el) => el.pl(76))
      .when(!collapsed, (el) =>
        el.child(
          h_flex()
            .flex_1()
            .gap(8)
            .items_center()
            .child(image("frame/welcome/herdr.png").size(19).rounded(5))
            .child(div().font_semibold().text_color(t.foreground).child("Herdr")),
        ),
      )
      .when(!collapsed, (el) =>
        el.child(this.button("search", svg("mods/personal-chrome/search.svg").size(14.5), () => run("mod.open", { name: "picker" }), "Jump to space or agent (Ctrl+Shift+K)")),
      )
      .when(!(collapsed && window()?.platform === "macos"), (el) =>
        el.child(
          this.button(
            "sidebar-toggle",
            svg("mods/personal-chrome/sidebar.svg").size(14.5),
            toggleSidebar,
            collapsed ? "Expand sidebar" : "Collapse sidebar to rail",
          ),
        ),
      );
  }
}
