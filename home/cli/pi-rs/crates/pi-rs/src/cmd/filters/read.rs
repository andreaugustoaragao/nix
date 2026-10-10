//! File and recovery reader with explicit ranges and targeted matching.

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::compress::{
    recovery,
    tee::{TruncateRequest, resolve_tee_dir, truncate_with_tee},
};
use clap::{Args, ValueEnum};

#[derive(ValueEnum, Clone, Debug, Default)]
pub enum Level {
    #[default]
    Raw,
    Signature,
    Aggressive,
}

#[derive(Args, Debug)]
pub struct Selection {
    /// First source line to inspect (one-based).
    #[arg(long, default_value_t = 1, value_parser = positive)]
    pub from: usize,
    /// Maximum source lines to inspect, starting at --from.
    #[arg(long)]
    pub lines: Option<usize>,
    /// Return matching source lines; supports regular expressions.
    #[arg(long)]
    pub grep: Option<String>,
    /// Treat --grep as a literal string.
    #[arg(short = 'F', long, requires = "grep")]
    pub fixed_strings: bool,
    /// Context around each matching line; overlapping ranges are merged.
    #[arg(short = 'C', long, default_value_t = 0, requires = "grep")]
    pub context: usize,
    /// Prefix returned lines with their original line numbers.
    #[arg(short = 'n', long)]
    pub line_numbers: bool,
}

impl Default for Selection {
    fn default() -> Self {
        Self {
            from: 1,
            lines: None,
            grep: None,
            fixed_strings: false,
            context: 0,
            line_numbers: false,
        }
    }
}

fn positive(value: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| "line numbers start at 1".into())
}

impl Selection {
    pub fn requested(&self) -> bool {
        self.from > 1 || self.lines.is_some() || self.grep.is_some() || self.line_numbers
    }

    pub fn apply(&self, text: &str) -> anyhow::Result<(String, bool)> {
        if !self.requested() {
            return Ok((text.to_owned(), true));
        }
        let source: Vec<&str> = text.split_inclusive('\n').collect();
        let start = self.from.saturating_sub(1).min(source.len());
        let end = self
            .lines
            .map_or(source.len(), |n| start.saturating_add(n).min(source.len()));
        let matcher = self
            .grep
            .as_ref()
            .map(|pattern| {
                regex::Regex::new(&if self.fixed_strings {
                    regex::escape(pattern)
                } else {
                    pattern.clone()
                })
            })
            .transpose()?;
        let mut selected = std::collections::BTreeSet::new();
        let mut matched = matcher.is_none();
        for (i, line) in source.iter().enumerate().take(end).skip(start) {
            if matcher.as_ref().is_none_or(|m| m.is_match(line)) {
                matched = true;
                selected.extend(
                    i.saturating_sub(self.context).max(start)
                        ..i.saturating_add(self.context).saturating_add(1).min(end),
                );
            }
        }
        let mut result = String::new();
        for i in selected {
            if self.line_numbers {
                result.push_str(&format!("{}:", i + 1));
            }
            result.push_str(source[i]);
        }
        Ok((result, matched))
    }
}

#[derive(Args, Debug)]
pub struct ReadArgs {
    /// File path or an unambiguous recovery hash prefix.
    pub path: PathBuf,
    #[arg(short, long, value_enum, default_value_t = Level::Raw)]
    pub level: Level,
    /// Return the full selected output, bypassing pi-rs's size limit.
    #[arg(long, alias = "full", conflicts_with = "level")]
    pub no_truncate: bool,
    /// Emit the structured Pi extension protocol for signature mode.
    #[arg(long)]
    pub json: bool,
    #[command(flatten)]
    pub selection: Selection,
}

fn resolve(path: &Path) -> anyhow::Result<PathBuf> {
    if path.exists() {
        return Ok(path.to_path_buf());
    }
    let Some(prefix) = path
        .to_str()
        .filter(|s| (8..=24).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_hexdigit()))
    else {
        anyhow::bail!("file not found: {}", path.display());
    };
    let directory = resolve_tee_dir(None)?;
    let candidates = std::fs::read_dir(directory)?
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().starts_with(prefix))
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .map(|e| e.path())
        .collect::<Vec<_>>();
    match candidates.as_slice() {
        [one] => Ok(one.clone()),
        [] => anyhow::bail!("recovery entry not found or expired: {prefix}"),
        _ => anyhow::bail!("ambiguous recovery prefix: {prefix}"),
    }
}

pub fn run(args: ReadArgs) -> anyhow::Result<()> {
    let path = resolve(&args.path)?;
    match args.level {
        Level::Signature | Level::Aggressive => {
            if args.selection.requested() {
                anyhow::bail!("signature mode cannot be combined with line selection");
            }
            crate::cmd::summary::run(crate::cmd::summary::Args {
                path,
                lang: None,
                min_body_lines: None,
                min_comment_lines: None,
                unfold_until_lines: Some(0),
                unfold_limit_lines: None,
                strict: false,
                json: args.json,
            })
        }
        Level::Raw => {
            if args.json {
                anyhow::bail!("--json is only available with --level signature");
            }
            let bytes = recovery::read(&path)?;
            if !args.selection.requested()
                && (args.no_truncate || std::str::from_utf8(&bytes).is_err())
            {
                std::io::stdout().write_all(&bytes)?;
                return Ok(());
            }
            let text = std::str::from_utf8(&bytes)?;
            let (selected, matched) = args.selection.apply(text)?;
            if args.no_truncate {
                print!("{selected}");
            } else {
                let result = truncate_with_tee(TruncateRequest {
                    content: &selected,
                    original: None,
                    head_lines: 2,
                    tail_lines: 1,
                    tee_dir: None,
                    max_bytes: None,
                })?;
                print!("{}", result.content);
            }
            if !matched {
                std::process::exit(1);
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_and_overlapping_match_context_preserve_source_coordinates() {
        let selection = Selection {
            from: 2,
            lines: Some(5),
            grep: Some("hit".into()),
            context: 1,
            line_numbers: true,
            ..Selection::default()
        };
        let (text, matched) = selection
            .apply("outside\na\nhit\nhit\nb\nc\noutside\n")
            .unwrap();
        assert!(matched);
        assert_eq!(text, "2:a\n3:hit\n4:hit\n5:b\n");
    }

    #[test]
    fn literals_and_no_match_are_unambiguous() {
        let selection = Selection {
            from: 1,
            grep: Some("a.b".into()),
            fixed_strings: true,
            ..Selection::default()
        };
        assert_eq!(
            selection.apply("axb\na.b\n").unwrap(),
            ("a.b\n".into(), true)
        );
        assert_eq!(selection.apply("axb\n").unwrap(), (String::new(), false));
    }
}
