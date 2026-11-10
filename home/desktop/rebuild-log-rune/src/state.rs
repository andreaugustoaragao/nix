use std::time::Duration;
use std::{
    cell::Cell,
    rc::Rc,
    sync::{Arc, Mutex},
};

use crate::log::{Level, Snapshot};
use rune::{Key, KeyEvent, TextEdit, Tx};

pub type Inbox = Arc<Mutex<Option<Snapshot>>>;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Filter {
    All,
    Issues,
    Errors,
}

pub struct State {
    pub log: Snapshot,
    pub inbox: Inbox,
    pub query: TextEdit,
    pub filter: Filter,
    pub only_matches: bool,
    pub visible: Vec<usize>,
    pub matches: Vec<usize>,
    pub current: usize,
    pub follow: bool,
    pub at_bottom: Rc<Cell<bool>>,
    pub wrap: bool,
    pub revision: u64,
    pub dark: Option<bool>,
    pub copied: bool,
}

impl Default for State {
    fn default() -> Self {
        Self::new(Snapshot::default(), Inbox::default())
    }
}

impl State {
    pub fn new(log: Snapshot, inbox: Inbox) -> Self {
        let mut state = Self {
            log,
            inbox,
            query: TextEdit::default(),
            filter: Filter::All,
            only_matches: false,
            visible: Vec::new(),
            matches: Vec::new(),
            current: 0,
            follow: true,
            at_bottom: Rc::new(Cell::new(true)),
            wrap: true,
            revision: 0,
            dark: None,
            copied: false,
        };
        state.reindex();
        state
    }

    pub fn reindex(&mut self) {
        let query = self.query.text.to_lowercase();
        self.visible.clear();
        self.matches.clear();
        for (i, line) in self.log.lines.iter().enumerate() {
            let allowed = match self.filter {
                Filter::All => true,
                Filter::Issues => line.level != Level::Info,
                Filter::Errors => line.level == Level::Error,
            };
            let matched = !query.is_empty() && line.text.to_lowercase().contains(&query);
            if allowed && (!self.only_matches || query.is_empty() || matched) {
                self.visible.push(i);
                if matched {
                    self.matches.push(i);
                }
            }
        }
        self.current = self.current.min(self.matches.len().saturating_sub(1));
        self.revision += 1;
        self.copied = false;
    }

    pub fn search(&mut self, tx: &mut Tx) {
        self.current = 0;
        self.follow = false;
        self.reindex();
        self.reveal(tx);
    }

    pub fn reveal(&self, tx: &mut Tx) {
        if let Some(i) = self.matches.get(self.current) {
            tx.scroll_into_view(self.log.lines[*i].key.clone());
        }
        tx.instant();
    }

    pub fn next(&mut self, backwards: bool, tx: &mut Tx) {
        if self.matches.is_empty() {
            return;
        }
        self.follow = false;
        self.current = if backwards {
            (self.current + self.matches.len() - 1) % self.matches.len()
        } else {
            (self.current + 1) % self.matches.len()
        };
        self.reveal(tx);
    }

    pub fn copy(&mut self, tx: &mut Tx) {
        let content = tx
            .text_selection()
            .map(|selection| selection.text().to_owned())
            .unwrap_or_else(|| {
                self.visible
                    .iter()
                    .map(|i| self.log.lines[*i].copy_text())
                    .collect::<Vec<_>>()
                    .join("\n")
            });
        tx.copy(content);
        self.copied = true;
    }

    pub fn resume(&mut self, tx: &mut Tx) {
        self.follow = true;
        self.at_bottom.set(true);
        tx.scroll_to_bottom_instant("log-stream");
        tx.instant();
    }
}

pub fn poll(state: &mut State, _: f64, tx: &mut Tx) -> bool {
    tx.wake_after(Duration::from_millis(250));
    let mut changed = false;
    if state.follow && !state.at_bottom.get() {
        state.follow = false;
        changed = true;
    }
    let snapshot = state.inbox.lock().expect("log inbox").take();
    if let Some(snapshot) = snapshot {
        state.log = snapshot;
        state.reindex();
        // Rune's stick-bottom scrolling preserves a reader's position off the end.
        changed = true;
    }
    changed
}

pub fn on_key(state: &mut State, key: &KeyEvent, tx: &mut Tx) -> bool {
    if key.is_command('f') {
        state.query.focused = true;
        state.follow = false;
        tx.instant();
        return true;
    }
    if key.is_command('w') {
        tx.close_window();
        return true;
    }
    if key.key == Key::Escape && state.query.focused {
        state.query = TextEdit::default();
        state.only_matches = false;
        state.reindex();
        tx.blur();
        return true;
    }
    if key.key == Key::Enter && state.query.focused {
        state.next(key.mods.shift, tx);
        return true;
    }
    if tx.focused().is_none() && key.key == Key::End {
        state.resume(tx);
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_and_severity_filters_compose_without_losing_lines() {
        let mut state = State::new(
            Snapshot::from_bytes(b"build started\nwarning: dirty checkout\nERROR: build failed\n"),
            Inbox::default(),
        );
        state.query.text = "BUILD".into();
        state.reindex();
        assert_eq!(state.visible, [0, 1, 2]);
        assert_eq!(state.matches, [0, 2]);
        state.only_matches = true;
        state.reindex();
        assert_eq!(state.visible, [0, 2]);
        state.filter = Filter::Errors;
        state.reindex();
        assert_eq!(state.visible, [2]);
        state.query.text.clear();
        state.filter = Filter::All;
        state.reindex();
        assert_eq!(state.visible, [0, 1, 2]);
    }

    #[test]
    fn quiet_polls_do_not_redraw_and_reading_history_pauses_following() {
        let mut state = State::default();
        let mut tx = Tx::default();
        assert!(!poll(&mut state, 0.0, &mut tx));
        state.at_bottom.set(false);
        assert!(poll(&mut state, 0.0, &mut tx));
        assert!(!state.follow);
        assert!(!poll(&mut state, 0.0, &mut tx));
        *state.inbox.lock().unwrap() = Some(Snapshot::from_bytes(b"new output\n"));
        assert!(poll(&mut state, 0.0, &mut tx));
        assert!(!state.follow);
        assert_eq!(state.log.lines[0].text, "new output");
    }
}
