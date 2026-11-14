// Pane header supporting both Crisp Gruvbox Islands (rounded card header with
// divider) and Flat Borderless mode (`props.flat = true`: stays on `t.background`
// so the workspace edge never zig-zags into the sidebar, and aligns its 14px
// horizontal rail with tabs, Intake, terminal_padding, and status).

import { View, div, svg, image } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, terminals, props, run, theme, home, layout } from "herdr";

function paneFrame(node) {
  if (!node || node.hidden) return null;
  if (node.content?.tab && node.content.pane) return node.content.pane;
  let children = node.children ?? [];
  if (node.type === "stack") {
    const visible = children.filter((child) => !child.hidden);
    children = [visible.find((child) => child.id === node.active) ?? visible[0]].filter(Boolean);
  }
  for (const child of children) {
    const frame = paneFrame(child);
    if (frame) return frame;
  }
  return null;
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint
    ? svg(p.icon).size(size).flex_none().text_color(color)
    : image(p.icon).w(size).h(size).flex_none();
}

function folder(cwd) {
  if (!cwd) return "";
  const h = home();
  return cwd === h ? "~" : cwd.startsWith(h + "/") ? "~" + cwd.slice(h.length) : cwd;
}

const clean = (s) => (s ?? "").replace(/^[^\p{L}\p{N}]+/u, "").trim();

function liveSubtitle(p, primary, role) {
  const raw = (p?.title ?? "").replace(/^[^\p{L}\p{N}~/]+/u, "");
  if (!raw || /^[~/]|^[A-Za-z]:\\/.test(raw) || raw.includes("@")) return "";
  const text = clean(p?.title);
  const lower = text.toLowerCase();
  const stripEllipsis = (s) => String(s ?? "").replace(/…$/, "").trim().toLowerCase();
  const normText = stripEllipsis(text);
  const normRole = stripEllipsis(role);
  if (
    !text ||
    lower === primary.toLowerCase() ||
    lower === (role ?? "").toLowerCase() ||
    (normRole && (normText.startsWith(normRole) || normRole.startsWith(normText))) ||
    lower === (p?.program?.name ?? "").toLowerCase() ||
    lower === (p?.program?.key ?? "").toLowerCase()
  ) {
    return "";
  }
  return text;
}

export default class PersonalPane extends View {
  init() {
    this.hovered = false;
  }

  me() {
    return panes().find((p) => p.pane === props()?.pane);
  }

  button(t, id, name, command, args) {
    return div()
      .id(id)
      .p(3)
      .rounded(5)
      .text_color(t.dim)
      .cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        run(command, args);
      })
      .child(svg(`mods/personal-pane/${name}.svg`).size(13.5));
  }

  render() {
    const t = theme();
    const p = this.me();
    if (!p) return div();
    const flat = Boolean(props()?.flat);
    const frame = paneFrame(layout());
    const bottom = frame?.header?.position === "bottom";
    const radius = flat ? 0 : Math.max(0, (frame?.radius ?? 10) - 1);
    const term = p.terminal ? terminals().find((item) => item.address === p.terminal) : null;
    const role = clean(term?.labels?.["herdr.name"] || term?.name || term?.labels?.["herdr.auto_name"] || "");
    const progName = p.program?.name || "shell";
    const name = role || ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || progName;
    const showProg = Boolean(role) && !role.toLowerCase().includes(progName.toLowerCase()) && !role.toLowerCase().includes((p.program?.key ?? "").toLowerCase());
    const sub = liveSubtitle(p, name, role);
    const branchSuffix = p.branch && p.branch !== "main" && p.branch !== "master" ? ` · ${p.branch}` : "";
    const pic = icon(p.program, 14, p.focused ? (flat ? t.accent : t.foreground) : t.dim);
    const st = p.status;
    const pane = p.pane;
    return h_flex()
      .id(`pane-head-${pane}`)
      .relative()
      .size_full()
      .px(flat ? 14 : 12)
      .gap(8)
      .items_center()
      .bg(flat ? t.background : (t.surface ?? t.background))
      .when(radius > 0 && !bottom, (el) => el.rounded_t(radius))
      .when(radius > 0 && bottom, (el) => el.rounded_b(radius))
      .when(!flat && bottom, (el) => el.border_t(1).border_color(t.border))
      .when(!flat && !bottom, (el) => el.border_b(1).border_color(t.border))
      .text_size(12)
      .on_hover((hovered, cx) => {
        this.hovered = hovered;
        cx.notify();
      })
      .on_click(() => run("pane.focus", { pane }))
      .when(flat && p.focused && !p.program?.tint, (el) =>
        el.child(div().size(6).rounded(3).flex_none().bg(t.accent)),
      )
      .when(Boolean(pic), (el) => el.child(pic))
      .child(
        div()
          .flex_none()
          .truncate()
          .max_w(220)
          .when(p.focused, (el) => el.font_semibold())
          .text_color(p.focused ? t.foreground : t.dim)
          .child(name),
      )
      .when(showProg, (el) =>
        el.child(div().flex_none().text_color(t.dim).child(`· ${progName}`)),
      )
      .when(Boolean(sub), (el) =>
        el.child(div().flex_shrink(1).min_w(0).max_w(260).truncate().text_color(p.focused ? t.muted : t.dim).child(`· ${sub}`)),
      )
      .child(div().flex_1().min_w(0).truncate().text_right().when(!flat, (el) => el.pr(2)).text_size(11.5).text_color(t.dim).child(`${folder(p.cwd)}${branchSuffix}`))
      .when(st === "working", (el) =>
        el.child(svg("mods/personal-pane/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)),
      )
      .when(st === "blocked", (el) =>
        el.child(
          div()
            .flex_none()
            .px(6)
            .h(18)
            .flex()
            .items_center()
            .rounded(5)
            .bg(t.blocked + "26")
            .text_size(10.5)
            .font_semibold()
            .text_color(t.blocked)
            .child("Needs you"),
        ),
      )
      .when(st === "done", (el) => el.child(div().size(7).flex_none().rounded(4).bg(t.done)))
      .when(this.hovered, (el) =>
        el
          .child(this.button(t, `ph-r-${pane}`, "split-right", "pane.split", { direction: "right", pane }))
          .child(this.button(t, `ph-d-${pane}`, "split-down", "pane.split", { direction: "down", pane }))
          .child(this.button(t, `ph-z-${pane}`, p.zoomed ? "unzoom" : "zoom", "pane.zoom", { pane }))
          .child(this.button(t, `ph-x-${pane}`, "close", "pane.close", { pane })),
      );
  }
}
