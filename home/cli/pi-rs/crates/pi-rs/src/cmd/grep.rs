//! `pi-rs grep` — ripgrep-backed search with omp-style hashline-anchored
//! grouped output.
//!
//! Behavior matches omp's `grep()` tool surface:
//!
//! - Multiline auto-enabled when the pattern contains a newline (literal or
//!   the two-char `\n`).
//! - `.gitignore` respected for directory walks (toggle via `--no-gitignore`).
//! - CLI context defaults to zero; extensions request their own context.
//! - Global `--skip` paginates across all files.
//! - Lines longer than `--max-columns` (default 1024) are truncated with `…`.
//! - Each directory page caps at `--limit` matches (default 100) and uses a
//!   round-robin across files so one hot file never monopolizes the page.
//! - Output is grouped by file with `# <path>` headers, blank line between
//!   groups, `*LINE+HASH|line` for matches and ` LINE+HASH|line` for context.
//! - Invalid `{...}` repetition syntax is auto-escaped so template strings
//!   like `${platform}` match as literals — same sanitization omp's
//!   `build_matcher()` does before regex compile.

use std::{
    collections::BTreeMap,
    collections::{BTreeSet, VecDeque},
    fs::{self, File},
    io::{self, Read},
    path::{Path, PathBuf},
};

use clap::Args as ClapArgs;
use grep_matcher::Matcher;
use grep_regex::RegexMatcherBuilder;
use grep_searcher::{
    BinaryDetection, Searcher, SearcherBuilder, Sink, SinkContext, SinkContextKind, SinkMatch,
};
use ignore::WalkBuilder;
use serde_json::json;

use crate::{hashline::compute_line_hash, proto};

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// Regex pattern. Multiline mode auto-enables when this contains a
    /// newline (literal or the two-char sequence `\n`).
    #[arg(long, short = 'e')]
    pub pattern: String,

    /// One or more files or directories to search. Repeat the flag
    /// for multiple targets.
    #[arg(long = "path", short = 'p', required = true, num_args = 1.., action = clap::ArgAction::Append)]
    pub paths: Vec<String>,

    /// Emit the Pi extension envelope and hashline anchors.
    #[arg(long)]
    pub json: bool,

    /// Match the pattern literally.
    #[arg(short = 'F', long)]
    pub fixed_strings: bool,

    /// Symmetric context around matches.
    #[arg(short = 'C', long)]
    pub context: Option<u32>,

    /// Case-insensitive matching.
    #[arg(short = 'i', long)]
    pub ignore_case: bool,

    /// Disable `.gitignore` traversal rules.
    #[arg(long)]
    pub no_gitignore: bool,

    /// Include hidden files / directories.
    #[arg(long, default_value_t = true)]
    pub hidden: bool,

    /// Context lines before each match.
    #[arg(short = 'B', long, default_value_t = 0)]
    pub context_before: u32,

    /// Context lines after each match.
    #[arg(short = 'A', long, default_value_t = 0)]
    pub context_after: u32,

    /// Maximum line width before truncation (chars).
    #[arg(long, default_value_t = 1024)]
    pub max_columns: u32,

    /// Maximum total matches to surface in the model-facing page.
    #[arg(long, default_value_t = 100)]
    pub limit: u32,

    /// Global match offset (pagination).
    #[arg(long, default_value_t = 0)]
    pub skip: u32,

    /// Matches per file in each round-robin batch (no matches discarded).
    #[arg(long)]
    pub per_file_cap: Option<u32>,
}

pub fn run(args: Args) -> anyhow::Result<()> {
    if args.pattern.trim().is_empty() {
        anyhow::bail!("Pattern must not be empty");
    }
    let multiline =
        args.pattern.contains('\n') || (!args.fixed_strings && args.pattern.contains("\\n"));

    let sanitized = if args.fixed_strings {
        regex::escape(&args.pattern)
    } else {
        sanitize_braces(&args.pattern)
    };
    let matcher = RegexMatcherBuilder::new()
        .case_insensitive(args.ignore_case)
        .multi_line(multiline)
        .build(&sanitized)
        .or_else(|_| {
            // Fallback: escape unescaped parentheses, matching omp's
            // build_matcher() retry.
            let retry = escape_unescaped_parens(&sanitized);
            RegexMatcherBuilder::new()
                .case_insensitive(args.ignore_case)
                .multi_line(multiline)
                .build(&retry)
        })?;

    let mut builder = SearcherBuilder::new();
    builder
        .binary_detection(BinaryDetection::quit(b'\x00'))
        .multi_line(multiline)
        .before_context(0)
        .after_context(0);
    let mut searcher = builder.build();

    // Collect all (path, file_matches) for each input path. Single-file and
    // multi-file have different per-file caps and grouping behavior.
    let mut all: Vec<FileHits> = Vec::new();
    let mut files_searched: u32 = 0;
    let mut missing: Vec<String> = Vec::new();
    let mut seen = BTreeSet::new();
    let before = args.context.unwrap_or(args.context_before) as usize;
    let after = args.context.unwrap_or(args.context_after) as usize;

    for path_str in &args.paths {
        let p = PathBuf::from(path_str);
        if !p.exists() {
            missing.push(path_str.clone());
            continue;
        }
        let md = fs::metadata(&p)?;
        if md.is_file() {
            if !seen.insert(fs::canonicalize(&p)?) {
                continue;
            }
            files_searched += 1;
            let hits = search_file(
                &mut searcher,
                &matcher,
                &p,
                p.display().to_string(),
                before,
                after,
            )?;
            if !hits.matches.is_empty() {
                all.push(hits);
            }
        } else if md.is_dir() {
            let walker = WalkBuilder::new(&p)
                .hidden(!args.hidden)
                .git_ignore(!args.no_gitignore)
                .git_exclude(!args.no_gitignore)
                .git_global(!args.no_gitignore)
                .build();
            for entry in walker {
                let entry = match entry {
                    Ok(e) => e,
                    Err(e) => {
                        missing.push(e.to_string());
                        continue;
                    }
                };
                if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
                    continue;
                }
                let abs = entry.path();
                if !seen.insert(fs::canonicalize(abs)?) {
                    continue;
                }
                files_searched += 1;
                let rel = abs.display().to_string();
                let hits = match search_file(&mut searcher, &matcher, abs, rel, before, after) {
                    Ok(h) => h,
                    Err(e) => {
                        missing.push(format!("{}: {e}", abs.display()));
                        continue;
                    }
                };
                if !hits.matches.is_empty() {
                    all.push(hits);
                }
            }
        }
    }

    let single_file_mode = args.paths.len() == 1
        && PathBuf::from(&args.paths[0])
            .metadata()
            .map(|m| m.is_file())
            .unwrap_or(false);
    let per_file_cap = args
        .per_file_cap
        .unwrap_or(if single_file_mode { 200 } else { 20 }) as usize;

    // Apply per-file caps and skip.
    let (visible_groups, total_matches, file_match_counts, limit_reached) =
        collate(all, per_file_cap, args.skip as usize, args.limit as usize);

    let full = format_output_with_notes(&visible_groups, single_file_mode, &missing, args.json, 0);
    let mut content = format_output_with_notes(
        &visible_groups,
        single_file_mode,
        &missing,
        args.json,
        args.max_columns as usize,
    );
    if !visible_groups.is_empty() && !missing.is_empty() {
        content.push_str(&format!(
            "\nSkipped missing paths: {}\n",
            missing.join(", ")
        ));
    }
    let file_count = visible_groups.len();
    let match_count: u32 = visible_groups.iter().map(|g| g.matches.len() as u32).sum();

    let next = args.skip as usize + match_count as usize;
    let note = if limit_reached {
        format!(
            "\n[showing {match_count} of {total_matches} matches; continue with --skip {next}]\n"
        )
    } else {
        String::new()
    };
    content.push_str(&note);
    let full = full + &note;
    let result = crate::compress::tee::truncate_with_tee(crate::compress::tee::TruncateRequest {
        content: &content,
        original: Some(&full),
        head_lines: 2,
        tail_lines: 1,
        tee_dir: None,
        max_bytes: None,
    })?;
    if !args.json {
        print!("{}", result.content);
        return Ok(());
    }
    proto::emit(
        &result.content,
        json!({
            "recoveryPath": result.tee_path,
            "truncated": result.truncated,
            "pattern": args.pattern,
            "matchCount": match_count,
            "totalMatches": total_matches,
            "fileCount": file_count,
            "filesSearched": files_searched,
            "files": visible_groups.iter().map(|g| &g.relative_path).collect::<Vec<_>>(),
            "fileMatches": file_match_counts,
            "limitReached": limit_reached,
            "missingPaths": missing,
        }),
    )
}

struct FileHits {
    relative_path: String,
    matches: Vec<MatchRecord>,
}

struct MatchRecord {
    line_number: u64,
    line: String,
    context_before: Vec<ContextLine>,
    context_after: Vec<ContextLine>,
}

struct ContextLine {
    line_number: u64,
    line: String,
}

fn search_file(
    searcher: &mut Searcher,
    matcher: &impl Matcher,
    abs: &Path,
    relative: String,
    before: usize,
    after: usize,
) -> anyhow::Result<FileHits> {
    let mut buf = Vec::new();
    let mut file = File::open(abs)?;
    file.read_to_end(&mut buf)?;
    let mut collector = Collector {
        matches: Vec::new(),
        max_columns: usize::MAX,
        pending_before: Vec::new(),
    };
    searcher
        .search_slice(matcher, &buf, &mut collector)
        .map_err(|e| anyhow::anyhow!("search failed: {e}"))?;
    let source = String::from_utf8_lossy(&buf);
    let lines: Vec<_> = source.lines().collect();
    for m in &mut collector.matches {
        let i = m.line_number.saturating_sub(1) as usize;
        let end = i + m.line.lines().count().max(1);
        m.context_before = (i.saturating_sub(before)..i)
            .map(|n| ContextLine {
                line_number: n as u64 + 1,
                line: lines[n].into(),
            })
            .collect();
        m.context_after = (end..end.saturating_add(after).min(lines.len()))
            .map(|n| ContextLine {
                line_number: n as u64 + 1,
                line: lines[n].into(),
            })
            .collect();
    }
    Ok(FileHits {
        relative_path: relative,
        matches: collector.matches,
    })
}

struct Collector {
    matches: Vec<MatchRecord>,
    max_columns: usize,
    pending_before: Vec<ContextLine>,
}

impl Sink for Collector {
    type Error = io::Error;
    fn matched(
        &mut self,
        _s: &Searcher,
        m: &SinkMatch<'_>,
    ) -> std::result::Result<bool, io::Error> {
        let raw = bytes_to_string(m.bytes());
        let (line, _) = truncate(raw, self.max_columns);
        self.matches.push(MatchRecord {
            line_number: m.line_number().unwrap_or(0),
            line,
            context_before: std::mem::take(&mut self.pending_before),
            context_after: Vec::new(),
        });
        Ok(true)
    }
    fn context(
        &mut self,
        _s: &Searcher,
        c: &SinkContext<'_>,
    ) -> std::result::Result<bool, io::Error> {
        let raw = bytes_to_string(c.bytes());
        let (line, _) = truncate(raw, self.max_columns);
        let cl = ContextLine {
            line_number: c.line_number().unwrap_or(0),
            line,
        };
        match c.kind() {
            SinkContextKind::Before => self.pending_before.push(cl),
            SinkContextKind::After => {
                if let Some(last) = self.matches.last_mut() {
                    last.context_after.push(cl);
                }
            }
            SinkContextKind::Other => {}
        }
        Ok(true)
    }
}

fn bytes_to_string(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(t) => t.trim_end_matches(['\n', '\r']).to_string(),
        Err(_) => String::from_utf8_lossy(bytes)
            .trim_end_matches(['\n', '\r'])
            .to_string(),
    }
}

fn truncate(line: String, max_columns: usize) -> (String, bool) {
    if line.chars().count() <= max_columns {
        return (line, false);
    }
    let mut out: String = line.chars().take(max_columns.saturating_sub(1)).collect();
    out.push('…');
    (out, true)
}

/// Apply per-file caps, global skip, and a round-robin scheduler so one hot
/// file doesn't monopolize the page. Mirrors omp's directory-output JS layer.
fn collate(
    mut all: Vec<FileHits>,
    per_file_cap: usize,
    skip: usize,
    limit: usize,
) -> (Vec<FileHits>, u32, BTreeMap<String, u32>, bool) {
    // A stable round-robin sequence makes every match reachable through skip.
    // The former per-file cap discarded later matches before pagination.
    all.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    let total = all.iter().map(|f| f.matches.len() as u32).sum();
    let counts = all
        .iter()
        .map(|f| (f.relative_path.clone(), f.matches.len() as u32))
        .collect();
    let mut taken: Vec<FileHits> = all
        .iter()
        .map(|f| FileHits {
            relative_path: f.relative_path.clone(),
            matches: Vec::new(),
        })
        .collect();
    let mut queues: Vec<VecDeque<_>> = all.into_iter().map(|f| f.matches.into()).collect();
    let mut offset = 0;
    let mut emitted = 0;
    let batch = per_file_cap.max(1);
    while queues.iter().any(|q| !q.is_empty()) && emitted < limit {
        for (i, q) in queues.iter_mut().enumerate() {
            for _ in 0..batch {
                let Some(m) = q.pop_front() else {
                    break;
                };
                if offset >= skip {
                    taken[i].matches.push(m);
                    emitted += 1;
                }
                offset += 1;
                if emitted >= limit {
                    break;
                }
            }
            if emitted >= limit {
                break;
            }
        }
    }
    let more = skip.saturating_add(emitted) < total as usize;
    (
        taken
            .into_iter()
            .filter(|f| !f.matches.is_empty())
            .collect(),
        total,
        counts,
        more,
    )
}

fn format_output_with_notes(
    groups: &[FileHits],
    single_file_mode: bool,
    missing: &[String],
    anchors: bool,
    width: usize,
) -> String {
    if groups.is_empty() {
        return if missing.is_empty() {
            "No matches found\n".into()
        } else {
            format!("No matches found. Skipped paths: {}\n", missing.join(", "))
        };
    }
    let mut out = String::new();
    let mut clipped = false;
    for group in groups {
        if !single_file_mode {
            out.push_str(&format!("# {}\n", group.relative_path));
        }
        let mut lines: BTreeMap<u64, (bool, &str)> = BTreeMap::new();
        for m in &group.matches {
            for c in m.context_before.iter().chain(&m.context_after) {
                lines.entry(c.line_number).or_insert((false, &c.line));
            }
            for (n, line) in m.line.lines().enumerate() {
                lines.insert(m.line_number + n as u64, (true, line));
            }
        }
        for (n, (matched, raw)) in lines {
            let (line, truncated) = if width == 0 {
                (raw.to_string(), false)
            } else {
                truncate(raw.to_string(), width)
            };
            clipped |= truncated;
            if anchors {
                out.push_str(&format!(
                    "{}{n}{}|{line}\n",
                    if matched { '*' } else { ' ' },
                    compute_line_hash(raw)
                ));
            } else {
                out.push_str(&format!("{n}{}{line}\n", if matched { ':' } else { '-' }));
            }
        }
    }
    if clipped {
        out.push_str(
            "[line widths clipped; use --max-columns 0 or read FILE --from LINE --lines 1]\n",
        );
    }
    out
}

/// Escape `{...}` runs that cannot be valid `{N}`/`{N,}`/`{N,M}` repetition
/// quantifiers so they match as literal braces. Also escapes a preceding
/// `$` when it directly precedes a `{...}` literal so template-string
/// patterns like `${platform}` match as literals instead of having `$`
/// behave as an end-of-line anchor.
///
/// This is a deliberate UX upgrade over omp's `build_matcher()` brace
/// sanitization, which only escapes braces (leaving `$` as an anchor).
fn sanitize_braces(pattern: &str) -> String {
    let bytes: Vec<char> = pattern.chars().collect();
    let mut out = String::with_capacity(pattern.len());
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c == '\\' && i + 1 < bytes.len() {
            out.push(c);
            out.push(bytes[i + 1]);
            i += 2;
            continue;
        }
        if c == '{' {
            // Scan ahead for a balanced closing `}`. If the body is one of
            // `N`, `N,`, `N,M` (digits + optional comma), treat as a real
            // quantifier and pass through unchanged. Else escape both braces
            // (and the immediately-preceding `$` when present — the model is
            // searching for a template literal, not a regex anchor).
            let mut j = i + 1;
            while j < bytes.len() && bytes[j] != '}' {
                j += 1;
            }
            if j < bytes.len() {
                let body: String = bytes[i + 1..j].iter().collect();
                if is_repetition_body(&body) {
                    out.extend(&bytes[i..=j]);
                    i = j + 1;
                    continue;
                }
                // Treat preceding unescaped `$` as part of the literal.
                if out.ends_with('$') && !out.ends_with("\\$") {
                    out.pop();
                    out.push_str("\\$");
                }
                out.push_str("\\{");
                out.push_str(&body);
                out.push_str("\\}");
                i = j + 1;
                continue;
            }
            // Unmatched `{` — escape it.
            out.push_str("\\{");
            i += 1;
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

fn is_repetition_body(body: &str) -> bool {
    if body.is_empty() {
        return false;
    }
    let mut seen_comma = false;
    for c in body.chars() {
        if c.is_ascii_digit() {
            continue;
        }
        if c == ',' && !seen_comma {
            seen_comma = true;
            continue;
        }
        return false;
    }
    true
}

/// Fallback for omp's "unopened/unclosed group" compile-error recovery.
/// Escape every unescaped `(` and `)` so accidental literal parens compile.
fn escape_unescaped_parens(pattern: &str) -> String {
    let bytes: Vec<char> = pattern.chars().collect();
    let mut out = String::with_capacity(pattern.len() + 8);
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c == '\\' && i + 1 < bytes.len() {
            out.push(c);
            out.push(bytes[i + 1]);
            i += 2;
            continue;
        }
        if c == '(' || c == ')' {
            out.push('\\');
        }
        out.push(c);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn template_string_becomes_literal_match() {
        // `${platform}` → the literal three-char run `${platform}` so the
        // model can search for template-style placeholders without
        // remembering regex escaping rules.
        assert_eq!(sanitize_braces("${platform}"), "\\$\\{platform\\}");
    }
    #[test]
    fn real_quantifier_kept() {
        assert_eq!(sanitize_braces("a{2,4}"), "a{2,4}");
        assert_eq!(sanitize_braces("a{3}"), "a{3}");
    }
    #[test]
    fn dollar_anchor_kept_when_no_brace_follows() {
        // Plain `$` (end-of-line anchor) is untouched.
        assert_eq!(sanitize_braces("foo$"), "foo$");
        assert_eq!(sanitize_braces("$bar"), "$bar");
    }
}
