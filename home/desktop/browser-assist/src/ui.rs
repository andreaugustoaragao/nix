use crate::backend::{Frame, Outcome, Task, Work};
use rune::{AppSpec, Color, Cx, El, Key, KeyEvent, TextEdit, TextStyle, Tx, col, el, row, text};
use rune_kit::{Kit, TextInput};
use serde_json::{Value, json};
use std::{
    sync::mpsc,
    time::{Duration, Instant},
};

pub struct State {
    send: Option<mpsc::Sender<Work>>,
    pub initial: Option<Result<Outcome, String>>,
    receive: Option<mpsc::Receiver<Result<Outcome, String>>>,
    pub frame: Option<Frame>,
    tasks: Vec<Task>,
    task: String,
    page: String,
    prompt: String,
    input: TextEdit,
    selected: Option<String>,
    busy: bool,
    error: String,
    last_frame: Instant,
    automatic: bool,
}

impl Default for State {
    fn default() -> Self {
        Self {
            send: None,
            initial: None,
            receive: None,
            frame: None,
            tasks: Vec::new(),
            task: String::new(),
            page: String::new(),
            prompt: String::new(),
            input: TextEdit::default().secure(),
            selected: None,
            busy: false,
            error: String::new(),
            last_frame: Instant::now(),
            automatic: true,
        }
    }
}

impl State {
    pub fn connected(
        send: mpsc::Sender<Work>,
        receive: mpsc::Receiver<Result<Outcome, String>>,
    ) -> Self {
        Self {
            send: Some(send),
            receive: Some(receive),
            busy: true,
            ..Self::default()
        }
    }

    pub fn initialize(&mut self, reply: Option<Result<Outcome, String>>) {
        match reply {
            Some(Ok(Outcome::Frame {
                task,
                page,
                prompt,
                frame,
            })) => {
                self.task = task;
                self.page = page;
                self.prompt = prompt;
                self.frame = Some(frame);
                self.busy = false;
            }
            Some(Ok(Outcome::Tasks(tasks))) => {
                self.tasks = tasks;
                self.busy = false;
            }
            other => self.initial = other,
        }
    }

    fn queue(&mut self, work: Work) {
        if self.busy {
            return;
        }
        if self
            .send
            .as_ref()
            .is_some_and(|send| send.send(work).is_ok())
        {
            self.busy = true;
            self.error.clear();
        }
    }

    fn act(&mut self, mut action: Value) {
        if self.busy {
            return;
        }
        if let Some(frame) = &self.frame {
            action["document"] = json!(frame.document);
            action["origin"] = json!(frame.location.origin);
            self.queue(Work::Act(action));
        }
    }

    fn clear_input(&mut self) {
        self.input = TextEdit::default().secure();
        self.selected = None;
    }

    fn submit(&mut self) {
        if self.busy {
            return;
        }
        // Take the value out of the editable UI as soon as it is submitted.
        let text = std::mem::take(&mut self.input.text);
        let action = if let Some(reference) = self.selected.take() {
            json!({"type":"fill","reference":reference,"text":text})
        } else {
            json!({"type":"text","text":text})
        };
        self.act(action);
        self.clear_input();
    }

    fn key(&mut self, key: &str) {
        self.clear_input();
        self.act(json!({"type":"key","key":key}));
    }
}

// Image Fit centres the PNG inside its element. Return CSS viewport coordinates,
// independent of window size, letterboxing, screenshot resolution, or display scale.
pub fn browser_point(
    rect: (f32, f32),
    pixels: (f32, f32),
    viewport: (f64, f64),
    point: (f32, f32),
) -> Option<(f64, f64)> {
    let scale = (rect.0 / pixels.0).min(rect.1 / pixels.1);
    let width = pixels.0 * scale;
    let height = pixels.1 * scale;
    let x = point.0 - (rect.0 - width) / 2.0;
    let y = point.1 - (rect.1 - height) / 2.0;
    if scale <= 0.0 || x < 0.0 || y < 0.0 || x >= width || y >= height {
        return None;
    }
    Some((
        f64::from(x / width) * viewport.0,
        f64::from(y / height) * viewport.1,
    ))
}

fn poll(s: &mut State, _: f64, tx: &mut Tx) -> bool {
    tx.wake_after(Duration::from_millis(100));
    let reply = s.initial.take().or_else(|| {
        s.receive
            .as_ref()
            .and_then(|receive| receive.try_recv().ok())
    });
    if let Some(reply) = reply {
        s.busy = false;
        match reply {
            Ok(Outcome::Tasks(tasks)) => s.tasks = tasks,
            Ok(Outcome::Frame {
                task,
                page,
                prompt,
                frame,
            }) => {
                if s.frame.as_ref().is_some_and(|old| {
                    old.document != frame.document || old.location.origin != frame.location.origin
                }) {
                    s.clear_input();
                }
                s.frame = Some(frame);
                s.task = task;
                s.page = page;
                s.prompt = prompt;
                s.last_frame = Instant::now();
            }
            Ok(Outcome::End) => {
                s.clear_input();
                s.frame = None;
                tx.close_window();
            }
            Err(error) => {
                s.error = error;
                s.clear_input();
            }
        }
        return true;
    }
    if s.automatic
        && s.frame.is_some()
        && !s.busy
        && s.error.is_empty()
        && s.selected.is_none()
        && s.input.text.is_empty()
        && !s.input.focused
        && s.last_frame.elapsed() >= Duration::from_secs(2)
    {
        s.queue(Work::Frame);
        return true;
    }
    false
}

#[derive(Clone, Copy)]
struct Palette {
    base: Color,
    panel: Color,
    text: Color,
    muted: Color,
    accent: Color,
    error: Color,
}

fn palette(dark: bool) -> Palette {
    let [base, panel, text, muted, accent, error] = if dark {
        [
            "#282828", "#3c3836", "#ebdbb2", "#bdae93", "#83a598", "#fb4934",
        ]
    } else {
        [
            "#fbf1c7", "#f2e5bc", "#3c3836", "#665c54", "#076678", "#9d0006",
        ]
    }
    .map(|hex| rune::color::hex(hex).unwrap());
    Palette {
        base,
        panel,
        text,
        muted,
        accent,
        error,
    }
}

fn button(
    key: &str,
    label: impl Into<String>,
    p: Palette,
    enabled: bool,
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
        .min_h(32.0)
        .px(10.0)
        .py(5.0)
        .radius(4.0)
        .center_y()
        .fill(p.accent.alpha(0.12))
        .hover(p.accent.alpha(0.22))
        .disabled(!enabled)
        .opacity(if enabled { 1.0 } else { 0.45 })
        .on_press_tx(action)
        .child(
            text(label)
                .font(TextStyle::new(13.0, 500.0))
                .color(p.text)
                .wrap(),
        )
}

fn page_key(s: &mut State, key: &KeyEvent, _: &mut Tx) -> bool {
    if s.busy {
        return true;
    }
    let key = match &key.key {
        Key::Enter => "Enter",
        Key::Tab => {
            if key.mods.shift {
                "Shift+Tab"
            } else {
                "Tab"
            }
        }
        Key::Escape => "Escape",
        Key::Backspace => "Backspace",
        Key::Delete => "Delete",
        Key::Left => "ArrowLeft",
        Key::Right => "ArrowRight",
        Key::Up => "ArrowUp",
        Key::Down => "ArrowDown",
        Key::Home => "Home",
        Key::End => "End",
        Key::Command('a') => "Control+a",
        Key::Text(value) => {
            s.input.text.push_str(value);
            s.input.focused = true;
            return true;
        }
        _ => return false,
    };
    s.key(key);
    true
}

fn view(s: &State, cx: &mut Cx<State>) -> El {
    let dark = cx.system_dark();
    let p = palette(dark);
    let k = Kit::neutral(dark);
    cx.reduced_motion(cx.system_reduced_motion());
    let mut root = col().w_full().h_full().fill(p.base).gap(0.0);
    let top = row()
        .w_full()
        .min_h(56.0)
        .px(18.0)
        .gap(12.0)
        .center_y()
        .fill(p.panel)
        .child(
            text("Browser assistance")
                .font(TextStyle::new(18.0, 600.0))
                .color(p.text),
        )
        .child(el().grow(1.0))
        .child(
            text(if s.busy {
                "Updating…"
            } else if s.frame.is_some() {
                "You have control"
            } else {
                "Choose a task"
            })
            .font(TextStyle::new(13.0, 500.0))
            .color(p.accent),
        );
    root = root.child(top);
    if !s.error.is_empty() {
        root = root.child(
            text(&s.error)
                .key("error")
                .color(p.error)
                .font(TextStyle::new(13.0, 500.0))
                .wrap()
                .px(18.0)
                .py(10.0),
        );
    }
    let Some(frame) = &s.frame else {
        let mut tasks = col()
            .w_full()
            .px(24.0)
            .py(24.0)
            .gap(14.0)
            .child(
                text("Help an agent sign in")
                    .font(TextStyle::new(24.0, 600.0))
                    .color(p.text),
            )
            .child(
                text("Choose a page. Agent actions pause while you use this window.")
                    .color(p.muted)
                    .wrap(),
            );
        for task in &s.tasks {
            for page in task.pages.keys() {
                let id = task.task.clone();
                let page = page.clone();
                let label = format!("{} / {} — {}", task.profile, page, task.label);
                tasks = tasks.child(button(
                    &format!("task-{id}-{page}"),
                    label,
                    p,
                    !s.busy && task.state == "active" && task.assistance.is_none(),
                    move |s, _| {
                        s.queue(Work::Begin {
                            task: id.clone(),
                            page: page.clone(),
                        })
                    },
                ));
            }
        }
        if s.tasks.is_empty() && !s.busy {
            tasks = tasks.child(
                text("No browser tasks are available. Ask your agent to start a task.")
                    .color(p.muted)
                    .wrap(),
            );
        }
        tasks = tasks
            .child(button("reload", "Refresh tasks", p, !s.busy, |s, _| {
                s.queue(Work::List)
            }))
            .child(button(
                "cancel-empty",
                "Close and keep task paused",
                p,
                !s.busy,
                |s, _| s.queue(Work::End(false)),
            ));
        return root.child(
            tasks
                .scroll(rune::ScrollSpec {
                    stick_bottom: false,
                })
                .grow(1.0),
        );
    };
    root = root.child(
        col()
            .w_full()
            .px(18.0)
            .py(10.0)
            .gap(3.0)
            .child(
                text(&frame.location.origin)
                    .key("origin")
                    .font(TextStyle::new(16.0, 600.0))
                    .color(p.accent)
                    .selectable(true),
            )
            .child(
                text(&frame.location.url)
                    .font(TextStyle::new(12.0, 400.0))
                    .color(p.muted)
                    .wrap_anywhere()
                    .selectable(true),
            ),
    );
    let preview = el()
        .key("screenshot")
        .grow(1.0)
        .h_full()
        .min_w(200.0)
        .pixels_fit(frame.image.pixels(), rune::SurfaceFit::Fit)
        .focusable(true)
        .focus_ring(2.0, 0.0, p.accent)
        .label(&frame.location.title)
        .cursor(rune::Cursor::Pointer)
        .disabled(s.busy)
        .on_drag(|s: &mut State, drag, _| {
            if drag.phase != rune::Phase::Up
                || drag.cancelled()
                || drag.dx.abs() > 4.0
                || drag.dy.abs() > 4.0
                || s.busy
            {
                return;
            }
            if let Some(frame) = &s.frame {
                if let Some([width, height]) = frame.image.size() {
                    if let Some((x, y)) = browser_point(
                        (drag.w, drag.h),
                        (width as f32, height as f32),
                        (frame.location.width, frame.location.height),
                        (drag.x, drag.y),
                    ) {
                        s.clear_input();
                        s.act(json!({"type":"click","x":x,"y":y}));
                    }
                }
            }
        })
        .on_key(page_key)
        .on_wheel(|s: &mut State, wheel, _| {
            if !s.busy && wheel.dy.abs() >= 1.0 {
                s.clear_input();
                s.act(json!({"type":"scroll","y":wheel.dy.clamp(-1200.0,1200.0) as i32}));
            }
            true
        });
    let mut panel = col().w(300.0).h_full().px(16.0).py(16.0).gap(10.0).fill(p.panel)
        .child(text(&s.prompt).font(TextStyle::new(15.0, 500.0)).color(p.text).wrap())
        .child(text("Click the page, or choose a field below. Input stays out of the agent conversation.").font(TextStyle::new(12.0, 400.0)).color(p.muted).wrap());
    let mut fields = col().w_full().gap(6.0);
    for (index, control) in frame
        .controls
        .iter()
        .enumerate()
        .filter(|(_, control)| control.field)
    {
        let reference = control.reference.clone();
        let label = if control.label.is_empty() {
            format!("Input {}", index + 1)
        } else {
            control.label.clone()
        };
        fields = fields.child(button(
            &format!("field-{index}"),
            if s.selected.as_ref() == Some(&reference) {
                format!("Editing: {label}")
            } else {
                label
            },
            p,
            !s.busy,
            move |s, _| {
                s.clear_input();
                s.selected = Some(reference.clone());
                s.input.focused = true;
            },
        ));
    }
    panel = panel
        .child(fields)
        .child(
            TextInput::new(&s.input)
                .secure()
                .label("Private input")
                .placeholder(if s.selected.is_some() {
                    "Enter a value for this field"
                } else {
                    "Type into the focused page field"
                })
                .on_edit(|s: &mut State| &mut s.input)
                .on_submit(|s: &mut State, _| s.submit())
                .disabled(s.busy)
                .build(&k)
                .key("private-input")
                .w_full(),
        )
        .child(button(
            "send-input",
            "Send input to page",
            p,
            !s.busy && !s.input.text.is_empty(),
            |s, _| s.submit(),
        ))
        .child(
            row()
                .gap(6.0)
                .child(button("tab", "Tab", p, !s.busy, |s, _| s.key("Tab")))
                .child(button("enter", "Enter", p, !s.busy, |s, _| s.key("Enter")))
                .child(button("escape", "Escape", p, !s.busy, |s, _| {
                    s.key("Escape")
                })),
        );
    let mut actions = col().w_full().gap(6.0);
    for (index, control) in frame
        .controls
        .iter()
        .enumerate()
        .filter(|(_, c)| !c.field && !c.label.is_empty())
    {
        let reference = control.reference.clone();
        actions = actions.child(button(
            &format!("action-{index}"),
            format!("{}: {}", control.role, control.label),
            p,
            !s.busy,
            move |s, _| {
                s.clear_input();
                s.act(json!({"type":"press","reference":reference}));
            },
        ));
    }
    panel = panel.child(actions).scroll(rune::ScrollSpec {
        stick_bottom: false,
    });
    root = root.child(
        row()
            .w_full()
            .grow(1.0)
            .min_h(0.0)
            .child(preview)
            .child(panel),
    );
    root.child(
        row()
            .w_full()
            .min_h(54.0)
            .px(14.0)
            .gap(8.0)
            .center_y()
            .fill(p.panel)
            .child(button(
                "refresh",
                "Refresh screenshot",
                p,
                !s.busy,
                |s, _| {
                    s.clear_input();
                    s.queue(Work::Frame);
                },
            ))
            .child(button(
                "automatic",
                if s.automatic {
                    "Auto-refresh on"
                } else {
                    "Auto-refresh off"
                },
                p,
                true,
                |s, _| s.automatic = !s.automatic,
            ))
            .child(el().grow(1.0))
            .child(button("cancel", "Keep paused", p, !s.busy, |s, _| {
                s.clear_input();
                s.queue(Work::End(false));
            }))
            .child(button(
                "continue",
                "Return control to agent",
                p,
                !s.busy,
                |s, _| {
                    s.clear_input();
                    s.queue(Work::End(true));
                },
            )),
    )
}

pub fn spec() -> AppSpec<State> {
    AppSpec {
        min_size: Some((800.0, 560.0)),
        poll: Some(poll),
        ..AppSpec::new("Browser assistance", (1260.0, 820.0), State::default, view)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_frame() -> Frame {
        let cache = rune::ImageCache::new(std::sync::Arc::new(|| {}));
        let image = cache.rgba(1200, 600, vec![255; 1200 * 600 * 4]);
        image.wait().unwrap();
        Frame {
            document: "document-one".into(),
            location: crate::backend::Location {
                origin: "https://example.test".into(),
                url: "https://example.test/login".into(),
                title: "Sign in".into(),
                width: 1200.0,
                height: 600.0,
            },
            controls: vec![crate::backend::Control {
                reference: "field-one".into(),
                label: "Password".into(),
                role: "textbox".into(),
                field: true,
            }],
            image,
        }
    }

    #[test]
    fn native_controls_send_private_input_and_scaled_clicks() {
        let (send, work) = mpsc::channel();
        let state = State {
            send: Some(send),
            frame: Some(fixture_frame()),
            automatic: false,
            ..State::default()
        };
        let mut rt = rune::App::new(spec())
            .init(move || state)
            .headless_runtime((1260.0, 820.0), rune::Env::new(true, 1.0));
        rt.frame(0.0);
        let click = |rt: &mut rune::Runtime<State>, key: &str| {
            let (x, y) = rt.find(key).unwrap();
            rt.pointer_down(x, y);
            rt.pointer_up(x, y);
            rt.frame(0.1);
        };
        click(&mut rt, "field-0");
        rt.key(KeyEvent {
            key: Key::Text("private-password-fixture".into()),
            mods: Default::default(),
        });
        rt.frame(0.1);
        assert_eq!(rt.state.input.text, "private-password-fixture");
        click(&mut rt, "send-input");
        let Work::Act(action) = work.try_recv().unwrap() else {
            panic!("Expected input action")
        };
        assert_eq!(
            action,
            json!({"type":"fill","reference":"field-one","text":"private-password-fixture","document":"document-one","origin":"https://example.test"})
        );
        assert!(rt.state.input.text.is_empty());
        assert!(rt.state.busy);
        rt.update(|s, _| s.busy = false);
        rt.frame(0.1);
        click(&mut rt, "screenshot");
        let Work::Act(action) = work.try_recv().unwrap() else {
            panic!("Expected screenshot click")
        };
        assert_eq!(action["type"], "click");
        assert!((action["x"].as_f64().unwrap() - 600.0).abs() < 1.0);
        assert!((action["y"].as_f64().unwrap() - 300.0).abs() < 1.0);
        rt.update(|s, _| s.busy = false);
        rt.frame(0.1);
        click(&mut rt, "continue");
        assert!(matches!(work.try_recv().unwrap(), Work::End(true)));
    }

    #[test]
    fn screenshot_clicks_account_for_letterboxing_and_hidpi() {
        assert_eq!(
            browser_point(
                (800.0, 600.0),
                (2400.0, 1200.0),
                (1200.0, 600.0),
                (400.0, 300.0)
            ),
            Some((600.0, 300.0))
        );
        assert_eq!(
            browser_point(
                (800.0, 600.0),
                (2400.0, 1200.0),
                (1200.0, 600.0),
                (400.0, 50.0)
            ),
            None
        );
        assert_eq!(
            browser_point(
                (600.0, 800.0),
                (600.0, 1200.0),
                (600.0, 1200.0),
                (100.0, 400.0)
            ),
            Some((0.0, 600.0))
        );
    }
}
