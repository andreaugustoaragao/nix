import { View, div } from "gpui-kit";
import { h_flex, v_flex, Slider, SliderState, SliderTrack, SliderIndicator, SliderThumb } from "gpui-base";
import { agents, terminals, panes, focused, props, home, appHome, theme, exec, shared, readTextFile, writeTextFile, nextCommand, window } from "herdr";
import Reader from "./reader.js";
import { selectedAgent } from "./selection.js";

export default class Preview extends View {
  init(_props, cx) {
    const options = props() || _props || {};
    this.sidebar = Boolean(options.sidebar);
    this.source = options.file ? "file" : "agent";
    this.selections = new Map();
    this.replies = [];
    this.question = "";
    this.questionExpanded = false;
    this.session = null;
    this.reply = -1;
    this.follow = true;
    this.replySlider = SliderState.new({ min: 0, max: 1, step: 0.001, value: 1 });
    this.replySlider.on("change", (value, cx) => {
      if (this.replies.length < 2) return;
      this.selectReply(Math.round(value * (this.replies.length - 1)), cx);
    });
    this.generation = 0;
    this.error = "";
    this.loading = false;
    this.nextRead = 0;
    this.handle = cx.focus_handle();
    this.pendingFocus = false;
    cx.spawn(async (cx) => {
      for (;;) {
        const command = await nextCommand();
        if (command === "focus") {
          this.pendingFocus = true;
          this.handle.focus();
          cx.notify();
        }
      }
    });
    const renderer = appHome() + "/mods/preview/renderer/render.mjs";
    const onOpenFile = (file, on, cx) => this.openFile(file, on, cx);
    this.fileReader = new Reader();
    this.fileReader.init({ embedded: true, readonly: true, renderer, onOpenFile }, cx);
    this.agentReader = new Reader();
    this.agentReader.init({ embedded: true, readonly: true, liveDocument: true, renderer, onOpenFile }, cx);
    if (options.file) this.openFile(options.file, options.on, cx);
    if (this.sidebar) {
      this.pollOpen(cx);
      cx.timer.every(1000, cx => this.pollOpen(cx));
    }
    cx.timer.every(1500, cx => {
      if (this.source === "agent") this.refreshAgent(cx);
    });
  }

  chooseAgent(cx) {
    const focus = focused();
    const selected = selectedAgent(focus, agents(), this.selections.get(focus?.tab), { terminals: terminals(), panes: panes() });
    if (selected) this.selections.set(focus.tab, selected.address);
    if (selected?.address === this.agent?.address) { this.agent = selected; return; }
    this.agent = selected;
    this.generation++;
    this.replies = [];
    this.question = "";
    this.questionExpanded = false;
    this.session = null;
    this.reply = -1;
    this.follow = true;
    this.error = "";
    this.loading = false;
    this.nextRead = 0;
    this.agentReader.mediaGeneration++;
    this.agentReader.text = this.agentReader.saved = null;
    this.agentReader.media = null;
    this.agentReader.mediaKey = "";
  }

  refreshAgent(cx, force = false) {
    this.chooseAgent(cx);
    if (!this.agent || this.loading || (!force && Date.now() < this.nextRead)) return;
    const generation = this.generation;
    const address = this.agent.address;
    this.loading = true;
    this.nextRead = Date.now() + 1500;
    cx.spawn(async cx => {
      try {
        const result = await exec("node", [appHome() + "/mods/preview/lib/read-agent.mjs", address]);
        if (generation !== this.generation || this.source !== "agent") return;
        if (result.code !== 0) throw new Error(result.stderr || "Could not read this agent.");
        const data = JSON.parse(result.stdout);
        const previous = this.replies[this.reply]?.id;
        this.replies = data.messages;
        if (this.follow) this.reply = this.replies.length - 1;
        else {
          const index = this.replies.findIndex(reply => reply.id === previous);
          this.reply = index < 0 ? 0 : index;
        }
        this.session = data.session;
        this.agentBase = data.cwd || home();
        this.truncated = data.truncated;
        this.error = "";
        this.showReply();
      } catch (error) {
        if (generation === this.generation) {
          this.question = "";
          this.questionExpanded = false;
          this.error = String(error?.message || error).slice(0, 500);
          this.agentReader.text = this.agentReader.saved = null;
          this.agentReader.media = null;
          this.agentReader.mediaGeneration++;
        }
      } finally {
        if (generation === this.generation) { this.loading = false; cx.notify(); }
      }
    });
  }

  showReply() {
    const question = this.replies[this.reply]?.question || "";
    if (question !== this.question) { this.question = question; this.questionExpanded = false; }
    this.replySlider.set_value(this.replies.length < 2 ? 1 : this.reply / (this.replies.length - 1));
    const text = this.replies[this.reply]?.text ?? null;
    const file = (this.agentBase || home()) + "/.agent-output.md";
    const reader = this.agentReader;
    if (reader.text === text && reader.file === file) return;
    reader.text = reader.saved = text;
    reader.file = file;
    reader.mediaGeneration++;
    reader.mediaKey = "";
    reader.media = null;
    reader.mediaError = "";
  }

  toggleQuestion(cx) {
    this.questionExpanded = !this.questionExpanded;
    cx.notify();
  }

  selectReply(index, cx) {
    const next = Math.max(0, Math.min(this.replies.length - 1, index));
    if (next === this.reply) return;
    this.reply = next;
    this.follow = this.reply === this.replies.length - 1;
    this.showReply();
    cx.notify();
  }

  openFile(file, on, cx, cwd) {
    this.source = "file";
    this.generation++;
    this.loading = false;
    this.fileReader.machine = on ?? null;
    this.fileReader.base = cwd || focused()?.cwd || home();
    this.fileReader.open(file, cx);
    cx.notify();
  }

  pollOpen(cx) {
    if (this.openBusy) return;
    this.openBusy = true;
    cx.spawn(async cx => {
      try {
        const raw = await readTextFile(appHome() + "/data/herdr-preview/open.json");
        if (!raw) return;
        const request = JSON.parse(raw);
        if (typeof request.id !== "string" || typeof request.file !== "string"
          || request.layout !== shared("layout")
          || request.id === localStorage.getItem("preview-opened")) return;
        this.openFile(request.file, null, cx, request.cwd);
        localStorage.setItem("preview-opened", request.id);
        const ack = appHome() + "/data/herdr-preview/opened.json";
        await writeTextFile(ack, JSON.stringify({ id: request.id }), await readTextFile(ack));
      } catch (error) { console.log("Preview open request:", String(error?.message || error)); }
      finally { this.openBusy = false; }
    });
  }

  syncOpen(cx) {
    const request = shared("herdr-preview.open");
    if (request && request.id !== this.openRequest) {
      this.openRequest = request.id;
      cx.timer.after(0, cx => {
        if (this.openRequest !== request.id) return;
        this.openFile(request.file, request.on, cx, request.cwd);
      });
    }
  }

  openExternal(cx) {
    const file = this.fileReader.file;
    if (!file || this.fileReader.machine) return;
    const isMac = window()?.platform === "macos";
    cx.spawn(async () => {
      try {
        if (isMac) {
          await exec("open", [file]);
        } else {
          await exec("sh", ["-c", 'xdg-open "$1" </dev/null >/dev/null 2>&1 &', "open", file]);
        }
      } catch (e) {
        console.log("Open external failed:", String(e?.message || e));
      }
    });
  }

  render(cx) {
    this.syncOpen(cx);
    if (this.pendingFocus) {
      this.pendingFocus = false;
      this.handle.focus();
    }
    if (this.source === "agent") this.refreshAgent(cx);
    const t = theme();
    const button = (id, text, action, active = false) => div().id("preview-" + id).px(10).py(6).rounded(6)
      .cursor_pointer().text_size(12).bg(active ? t.selected : t.raised).text_color(active ? t.accent : t.foreground)
      .hover(s => s.bg(t.hover)).on_click(action).child(text);
    const source = this.source === "agent";
    const reader = source ? this.agentReader : this.fileReader;
    const filename = this.fileReader.file.split(/[\\/]/).pop();
    return v_flex().id("herdr-preview").size_full().min_w(0).min_h(0)
      .track_focus(this.handle)
      .on_mouse_down("left", () => this.handle.focus())
      .on_size_change((size, cx) => {
        if (this.fileReader.width === size.width && this.fileReader.height === size.height) return;
        for (const child of [this.fileReader, this.agentReader]) { child.width = size.width; child.height = size.height; }
        cx.notify();
      }).rounded(10).overflow_hidden()
      .bg(t.surface).text_color(t.foreground).border_1().border_color(this.handle.is_focused() ? t.accent : t.border)
      .on_drop((event, cx) => { if (event.paths?.length) this.openFile(event.paths[0], null, cx); })
      .child(h_flex().px(12).py(10).gap(6).items_center()
        .child(button("agent", "Agent", (_e, cx) => { this.source = "agent"; this.nextRead = 0; cx.notify(); }, source))
        .child(button("file", "File", (_e, cx) => { this.source = "file"; this.generation++; this.loading = false; cx.notify(); }, !source))
        .when(!source, el => el.child(div().id("preview-filename").flex_1().min_w(0).ml(4).truncate()
          .text_size(12).text_color(t.muted)
          .tooltip(this.fileReader.machine ? this.fileReader.machine + ":" + this.fileReader.file : this.fileReader.file)
          .child(filename || "No file selected")))
        .when(!source && Boolean(this.fileReader.file) && !this.fileReader.machine, el => el.child(
          button("open", "Open", (_e, cx) => { cx.stop_propagation(); this.openExternal(cx); })
            .flex_none()
            .tooltip("Open in default application (xdg-open)")))
        .when(source && this.replies.length > 1, el => el.child(
          Slider.new(this.replySlider).flex_1().min_w(40).ml(4).mr(6)
            .accessibility_label("Agent reply history")
            .tooltip("Browse replies · drag to the right edge to follow latest")
            .child(SliderTrack.new(this.replySlider).flex().items_center().h(28).w_full().child(
              SliderIndicator.new(this.replySlider).relative().w_full().h(3).rounded(2).bg(t.border)
                .range_style(fill => fill.rounded(2).bg(t.accent))
                .child(SliderThumb.new(this.replySlider).size(10).ml(-5).mt(-5).rounded(5).bg(t.accent))))))
        .when(source && this.replies.length < 2, el => el.child(div().flex_1()))
        .when(source && this.replies.length > 0, el => el.child(div().text_size(10).flex_none()
          .text_color(this.follow ? t.accent : t.muted)
          .tooltip(this.follow ? "Following latest reply" : "Earlier reply · drag the slider right to follow latest")
          .child((this.reply + 1) + "/" + this.replies.length))))
      .when(source && Boolean(this.question), el => el.child(
        h_flex().id("preview-question").flex_none().min_w(0).mx(12).mb(6).px(10).py(8).gap(8)
          .rounded(6).bg(t.raised).text_color(t.muted).cursor_pointer()
          .accessibility_label(this.questionExpanded ? "Collapse question" : "Expand question")
          .tooltip(this.questionExpanded ? "Click to collapse question" : "Click to expand question")
          .on_click((_event, cx) => this.toggleQuestion(cx))
          .child(div().flex_none().text_size(11).line_height("18px").child(this.questionExpanded ? "▾" : "▸"))
          .child(div().id("preview-question-text").flex_1().min_w(0).text_size(12).line_height("18px")
            .max_h(this.questionExpanded ? 180 : 36)
            .when(this.questionExpanded, text => text.overflow_scroll())
            .when(!this.questionExpanded, text => text.overflow_hidden())
            .child(this.questionExpanded ? this.question : this.question.replace(/\s+/g, " ")))))
      .when(source && Boolean(this.error), el => el.child(div().p(14).text_size(12).text_color(t.blocked).child(this.error)))
      .child(source && reader.text === null
        ? v_flex().flex_1().p(24).gap(10)
          .child(div().text_size(16).font_semibold().child(this.agent ? "Waiting for assistant output" : "Select an agent"))
          .child(div().text_size(12).text_color(t.muted).child("Markdown and Mermaid from the selected agent appear here. Use the reply slider to browse earlier output."))
        : reader.render(cx).flex_1().min_w(0).min_h(0))
      .when(source && Boolean(this.session), el => el.child(div().px(12).py(6).text_size(10).text_color(t.dim)
        .child((this.agent?.address || "") + " · " + this.session + (this.truncated ? " · recent transcript window" : ""))));
  }
}
