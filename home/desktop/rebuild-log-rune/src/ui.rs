use rune::{AppSpec, Color, Cx, El, GrowthSpec, ScrollSpec, TextStyle, Tx, col, el, row, text};
use rune_kit::{Kit, ScrollBar, TextInput};

use crate::{
    log::Level,
    state::{Filter, State, on_key, poll},
};

const MONO: TextStyle = TextStyle::new(13.5, 400.0).mono().lh(21.0);
const UI: TextStyle = TextStyle::new(13.0, 500.0);

#[derive(Clone, Copy)]
struct Palette {
    base: Color,
    chrome: Color,
    text: Color,
    muted: Color,
    border: Color,
    accent: Color,
    warning: Color,
    error: Color,
}

fn palette(dark: bool) -> Palette {
    let hex = if dark {
        [
            "#282828", "#3c3836", "#ebdbb2", "#a89984", "#504945", "#83a598", "#fabd2f", "#fb4934",
        ]
    } else {
        [
            "#fbf1c7", "#f2e5bc", "#3c3836", "#7c6f64", "#d5c4a1", "#076678", "#b57614", "#9d0006",
        ]
    };
    let [base, chrome, text, muted, border, accent, warning, error] =
        hex.map(|value| rune::color::hex(value).expect("palette"));
    Palette {
        base,
        chrome,
        text,
        muted,
        border,
        accent,
        warning,
        error,
    }
}

fn button(
    key: &str,
    label: impl Into<String>,
    p: Palette,
    active: bool,
    action: impl Fn(&mut State, &mut Tx) + 'static,
) -> El {
    let label = label.into();
    row()
        .key(key)
        .role("button")
        .label(label.clone())
        .focusable(true)
        .focus_ring(2.0, 2.0, p.accent)
        .cursor(rune::Cursor::Pointer)
        .h(30.0)
        .px(10.0)
        .center()
        .radius(4.0)
        .fill(if active {
            p.accent.alpha(0.16)
        } else {
            Color::TRANSPARENT
        })
        .hover(p.accent.alpha(0.10))
        .on_press_tx(move |s: &mut State, tx| {
            action(s, tx);
            tx.instant();
        })
        .child(
            text(label)
                .font(UI)
                .color(if active { p.accent } else { p.text }),
        )
}

fn choose_filter(s: &mut State, filter: Filter, tx: &mut Tx) {
    s.filter = filter;
    s.follow = false;
    s.reindex();
    tx.scroll_to_instant("log-stream", 0.0, 0.0);
}

pub fn view(s: &State, cx: &mut Cx<State>) -> El {
    let dark = s.dark.unwrap_or(cx.system_dark());
    let p = palette(dark);
    let reduced_motion = cx.system_reduced_motion();
    cx.reduced_motion(reduced_motion);
    let k = Kit::neutral(dark);
    let errors = s
        .log
        .lines
        .iter()
        .filter(|line| line.level == Level::Error)
        .count();
    let warnings = s
        .log
        .lines
        .iter()
        .filter(|line| line.level == Level::Warning)
        .count();
    let (phase, phase_color) = match s.log.phase.as_str() {
        "starting" => ("Starting", p.accent),
        "building" => ("Building", p.accent),
        "applying" => ("Applying", p.warning),
        "done" => ("Applied", p.accent),
        "failed" => ("Failed", p.error),
        "cancelled" => ("Not applied", p.warning),
        "interrupted" => ("Interrupted", p.warning),
        _ => ("Log", p.muted),
    };
    let header = row()
        .w_full()
        .h(52.0)
        .px(14.0)
        .gap(8.0)
        .center_y()
        .fill(p.chrome)
        .child(
            text("Rebuild log")
                .font(TextStyle::new(18.0, 600.0))
                .color(p.text),
        )
        .child(text(phase).key("phase").font(UI).color(phase_color).ml(8.0))
        .child(el().grow(1.0))
        .child(
            button(
                "follow",
                if s.follow { "Following" } else { "Follow" },
                p,
                s.follow,
                |s, tx| {
                    if s.follow {
                        s.follow = false;
                    } else {
                        s.resume(tx);
                    }
                },
            )
            .help("Follow new output. Scrolling back pauses following; End resumes it."),
        )
        .child(
            button("wrap", "Wrap", p, s.wrap, |s, _| {
                s.wrap = !s.wrap;
                s.revision += 1;
            })
            .help("Wrap long lines instead of scrolling sideways"),
        )
        .child(
            button(
                "copy",
                if s.copied { "Copied" } else { "Copy" },
                p,
                false,
                |s, tx| s.copy(tx),
            )
            .keeps_text_selection()
            .help("Copy selected text, or all filtered lines if nothing is selected"),
        );

    let search = TextInput::new(&s.query)
        .label("Search log")
        .placeholder("Search log…")
        .on_edit(|s: &mut State| &mut s.query)
        .on_change(|s: &mut State, tx| s.search(tx))
        .on_key(on_key)
        .build(&k)
        .key("search")
        .grow(1.0)
        .min_w(130.0);
    let count = if s.query.text.is_empty() {
        String::new()
    } else if s.matches.is_empty() {
        "No matches".into()
    } else {
        format!("{} / {}", s.current + 1, s.matches.len())
    };
    let searchbar = row()
        .w_full()
        .min_h(44.0)
        .px(14.0)
        .gap(6.0)
        .center_y()
        .fill(p.base)
        .child(search)
        .child(text(count).key("match-count").font(UI).color(p.muted))
        .child(
            button("previous", "Previous", p, false, |s, tx| s.next(true, tx))
                .disabled(s.matches.is_empty())
                .opacity(if s.matches.is_empty() { 0.45 } else { 1.0 })
                .help("Previous match (Shift+Enter)"),
        )
        .child(
            button("next", "Next", p, false, |s, tx| s.next(false, tx))
                .disabled(s.matches.is_empty())
                .opacity(if s.matches.is_empty() { 0.45 } else { 1.0 })
                .help("Next match (Enter)"),
        )
        .child(
            button(
                "filter-matches",
                "Filter matches",
                p,
                s.only_matches,
                |s, tx| {
                    s.only_matches = !s.only_matches;
                    s.search(tx);
                },
            )
            .disabled(s.query.text.is_empty())
            .opacity(if s.query.text.is_empty() { 0.45 } else { 1.0 }),
        );
    let filters = row()
        .w_full()
        .h(38.0)
        .px(14.0)
        .gap(4.0)
        .center_y()
        .child(button("all", "All", p, s.filter == Filter::All, |s, tx| {
            choose_filter(s, Filter::All, tx)
        }))
        .child(
            button(
                "issues",
                format!("Issues {}", warnings + errors),
                p,
                s.filter == Filter::Issues,
                |s, tx| choose_filter(s, Filter::Issues, tx),
            )
            .help("Lines with warning or error message prefixes"),
        )
        .child(button(
            "errors",
            format!("Errors {errors}"),
            p,
            s.filter == Filter::Errors,
            |s, tx| choose_filter(s, Filter::Errors, tx),
        ))
        .child(el().grow(1.0))
        .child(
            text(format!("{} / {} lines", s.visible.len(), s.log.lines.len()))
                .key("line-count")
                .font(UI)
                .color(p.muted),
        );

    let at_bottom = s.at_bottom.clone();
    let timestamps = s.log.lines.iter().any(|line| line.timestamp.is_some());
    let width = if s.wrap {
        0.0
    } else {
        s.visible
            .iter()
            .map(|i| s.log.lines[*i].text.chars().count())
            .max()
            .unwrap_or(0) as f32
            * 9.0
            + if timestamps { 232.0 } else { 92.0 }
    };
    let rows = col()
        .key("log-rows")
        .w_full()
        .min_w(width)
        .growth(GrowthSpec::default())
        .selection_group(true)
        .instant_changes()
        .virtual_rows(
            s.visible.len(),
            23.0,
            |s: &State, i| s.log.lines[s.visible[i]].key.as_str().into(),
            move |s: &State, i| {
                let index = s.visible[i];
                let line = &s.log.lines[index];
                let color = match line.level {
                    Level::Info => p.text,
                    Level::Warning => p.warning,
                    Level::Error => p.error,
                };
                let matched = s.matches.binary_search(&index).is_ok();
                let current = s.matches.get(s.current) == Some(&index);
                let mut message = text(&line.text)
                    .key(format!("message-{index}"))
                    .font(MONO)
                    .color(color)
                    .selectable(true)
                    .selection_color(p.accent.alpha(0.30))
                    .grow(1.0)
                    .min_w(0.0);
                if s.wrap {
                    message = message.wrap_anywhere();
                }
                let mut log_row = row()
                    .w_full()
                    .min_h(23.0)
                    .px(14.0)
                    .py(1.0)
                    .gap(12.0)
                    .fill(if current {
                        p.warning.alpha(0.15)
                    } else if matched {
                        p.warning.alpha(0.07)
                    } else {
                        Color::TRANSPARENT
                    })
                    .child(
                        text(format!("{}", index + 1))
                            .font(MONO)
                            .color(p.muted)
                            .w(56.0),
                    );
                if timestamps {
                    let stamp = line
                        .timestamp
                        .map(|time| time.format("%d %b %H:%M:%S").to_string())
                        .unwrap_or_else(|| "—".into());
                    let details = line
                        .timestamp
                        .map(|time| time.format("%d %b %Y, %H:%M:%S UTC%:z").to_string())
                        .unwrap_or_else(|| {
                            "Capture time unavailable for this older log line.".into()
                        });
                    log_row = log_row.child(
                        text(stamp)
                            .key(format!("timestamp-{index}"))
                            .font(TextStyle::new(11.5, 400.0).mono().lh(21.0))
                            .color(p.muted)
                            .w(128.0)
                            .help(details),
                    );
                }
                log_row.child(message)
            },
        )
        .virtual_rows_version(s.revision);
    let stream = col()
        .key("log-stream")
        .role("log")
        .label("Rebuild output")
        .w_full()
        .grow(1.0)
        .min_h(0.0)
        .min_w(0.0)
        .scroll(ScrollSpec {
            stick_bottom: s.follow,
        })
        .scroll_anchor()
        .on_scroll_offset(move |position| at_bottom.set(position.max[1] - position.offset[1] < 3.0))
        .child(rows)
        .scroll_bar(&k);
    let footer = row()
        .w_full()
        .h(30.0)
        .px(14.0)
        .center_y()
        .fill(p.chrome)
        .child(
            text(if s.log.truncated {
                "History limited to 16 MiB / 100,000 lines; numbers refer to the retained tail."
            } else if !timestamps && !s.log.lines.is_empty() {
                "Older output has no capture times. New rebuilds will show timestamps."
            } else {
                "Ctrl+F search   Enter / Shift+Enter matches   End follow   Ctrl+W close"
            })
            .font(TextStyle::new(11.0, 400.0))
            .color(p.muted),
        );
    let mut root = col()
        .key("rebuild-log")
        .w_full()
        .h_full()
        .min_h(0.0)
        .fill(p.base)
        .child(header)
        .child(searchbar)
        .child(filters)
        .child(el().w_full().h(1.0).fill(p.border));
    if let Some(error) = &s.log.error {
        root = root.child(
            text(error)
                .key("read-error")
                .role("alert")
                .font(UI)
                .color(p.error)
                .wrap_anywhere()
                .w_full()
                .padding(14.0),
        );
    } else if !s.log.message.is_empty() {
        root = root.child(
            text(&s.log.message)
                .key("status-message")
                .font(UI)
                .color(phase_color)
                .wrap()
                .max_lines(2)
                .w_full()
                .padding(14.0),
        );
    }
    if s.visible.is_empty() {
        root = root.child(
            col().grow(1.0).w_full().center().child(
                text(if s.log.lines.is_empty() {
                    "No output yet. This window will update when the log changes."
                } else {
                    "No lines match. Clear the search or choose All."
                })
                .font(UI)
                .color(p.muted)
                .wrap()
                .max_w(440.0),
            ),
        );
    } else {
        root = root.child(stream);
    }
    root.child(footer)
}

pub fn spec() -> AppSpec<State> {
    AppSpec {
        min_size: Some((620.0, 360.0)),
        families: ("Noto Sans", "Cascadia Code"),
        fonts: &[include_bytes!("../assets/CascadiaCode.otf")],
        poll: Some(poll),
        on_key: Some(on_key),
        scenes: &[
            ("dark", |s| s.dark = Some(true)),
            ("light", |s| s.dark = Some(false)),
        ],
        ..AppSpec::new("NixOS rebuild log", (1160.0, 760.0), State::default, view)
    }
}
