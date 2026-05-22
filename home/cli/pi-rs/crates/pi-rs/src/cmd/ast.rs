//! `pi-rs ast-grep` and `pi-rs ast-edit` — structural search and rewrite
//! across files / directories, hashline-anchored output.
//!
//! Architectural notes:
//!
//! - The vendored `pi_ast::ops` module exposes the primitives (language
//!   resolution, pattern compilation, match collection, rewrite
//!   application).
//! - File discovery uses `ignore::WalkBuilder` (mirrors `grep.rs` and matches
//!   omp's `fs_cache` walker behavior modulo the in-process LRU).
//! - Output is JSON via `proto::emit`, identical in shape to omp's
//!   `AstFindResult` / `AstReplaceResult` so the TS extension can deserialize
//!   directly. The `content` field carries the model-facing text.
//!
//! Behavior parity with omp (`crates/pi-natives/src/ast.rs`):
//!
//! - Single pattern per search (omp accepts a `patterns` list; we
//!   currently take one — the orchestrator iterates if needed).
//! - Glob filter applied AFTER discovery, matched against the relative path.
//! - Language inferred per-file from extension when `--lang` is omitted.
//! - For ast-edit, an explicit `--lang` is required when discovery resolves
//!   to multiple languages (no auto-coercion across languages).
//! - Per-replacement and per-file caps enforced.
//! - Dry-run by default; `--apply` writes to disk via `pi_ast::ops::apply_edits`.

use std::{
	collections::{BTreeMap, BTreeSet, HashMap},
	path::{Path, PathBuf},
};

use ast_grep_core::{MatchStrictness, matcher::Pattern, source::Edit, tree_sitter::LanguageExt};
use clap::Args as ClapArgs;
use globset::{Glob, GlobSet, GlobSetBuilder};
use ignore::WalkBuilder;
use pi_ast::{
	SupportLang,
	ops::{self as shared_ops},
};
use serde::Serialize;
use serde_json::{Value, json};

use crate::proto;

const DEFAULT_FIND_LIMIT: u32 = 50;
const DEFAULT_MAX_FILES: u32 = 1000;
const DEFAULT_MAX_REPLACEMENTS: u32 = u32::MAX;

// ─── ast-grep ──────────────────────────────────────────────────────────────

#[derive(ClapArgs, Debug)]
pub struct AstGrepArgs {
	/// Structural pattern (ast-grep syntax).
	#[arg(long, short = 'e')]
	pub pattern: String,
	/// One or more files / directories. Repeat the flag for multiple targets.
	#[arg(long = "path", short = 'p', required = true, num_args = 1.., action = clap::ArgAction::Append)]
	pub paths: Vec<String>,
	/// Optional glob filter (relative to each search root).
	#[arg(long)]
	pub glob: Option<String>,
	/// Language override; otherwise inferred from each file's extension.
	#[arg(long)]
	pub lang: Option<String>,
	/// Rule selector for contextual ast-grep patterns.
	#[arg(long)]
	pub selector: Option<String>,
	/// Match strictness: cst, smart (default), ast, relaxed, signature, template.
	#[arg(long, default_value = "smart")]
	pub strictness: String,
	/// Maximum matches to return.
	#[arg(long, default_value_t = DEFAULT_FIND_LIMIT)]
	pub limit: u32,
	/// Skip the first N matches (pagination).
	#[arg(long, default_value_t = 0)]
	pub offset: u32,
	/// Include captured meta-variable bindings for every match.
	#[arg(long, default_value_t = false)]
	pub include_meta: bool,
}

#[derive(Serialize)]
struct AstFindMatch {
	path: String,
	text: String,
	#[serde(rename = "byteStart")]
	byte_start: u32,
	#[serde(rename = "byteEnd")]
	byte_end: u32,
	#[serde(rename = "startLine")]
	start_line: u32,
	#[serde(rename = "startColumn")]
	start_column: u32,
	#[serde(rename = "endLine")]
	end_line: u32,
	#[serde(rename = "endColumn")]
	end_column: u32,
	#[serde(rename = "metaVariables", skip_serializing_if = "Option::is_none")]
	meta_variables: Option<HashMap<String, String>>,
}

pub fn grep_run(args: AstGrepArgs) -> anyhow::Result<()> {
	let pattern = args.pattern.trim();
	if pattern.is_empty() {
		anyhow::bail!("Pattern must not be empty");
	}
	let strictness = parse_strictness(&args.strictness)?;
	let explicit_lang = args.lang.as_deref().map(str::trim).filter(|v| !v.is_empty());

	let candidates = collect_candidates(&args.paths, args.glob.as_deref(), explicit_lang)?;
	let files_searched = candidates.len() as u32;

	// Compile patterns per language present in the candidate set. We dedupe
	// by canonical name (SupportLang is not Ord).
	let mut patterns_by_lang: HashMap<String, Pattern> = HashMap::new();
	let mut parse_errors: Vec<String> = Vec::new();
	{
		let mut needed_langs: BTreeMap<&'static str, SupportLang> = BTreeMap::new();
		for c in &candidates {
			if let Some(lang) = c.language {
				needed_langs.entry(lang.canonical_name()).or_insert(lang);
			}
		}
		for (_key, lang) in needed_langs {
			let key = lang.canonical_name().to_string();
			match shared_ops::compile_pattern(pattern, args.selector.as_deref(), &strictness, lang) {
				Ok(p) => {
					patterns_by_lang.insert(key, p);
				}
				Err(e) => {
					parse_errors.push(format!("{pattern}: {key}: {e}"));
				}
			}
		}
	}

	let mut all_matches: Vec<AstFindMatch> = Vec::new();
	let mut total_matches: u32 = 0;
	let mut files_with_matches: BTreeSet<String> = BTreeSet::new();
	for cand in &candidates {
		let lang = match cand.language {
			Some(l) => l,
			None => continue,
		};
		let lang_key = lang.canonical_name().to_string();
		let compiled = match patterns_by_lang.get(&lang_key) {
			Some(p) => p,
			None => continue, // compile error captured above
		};
		let source = match std::fs::read_to_string(&cand.absolute_path) {
			Ok(s) => s,
			Err(err) => {
				parse_errors.push(format!("{pattern}: {}: {err}", cand.display_path));
				continue;
			}
		};
		let ast = lang.ast_grep(&source);
		if ast.root().dfs().any(|node| node.is_error()) {
			parse_errors.push(format!(
				"{}: parse error (syntax tree contains error nodes)",
				cand.display_path
			));
		}
		for matched in ast.root().find_all(compiled.clone()) {
			total_matches = total_matches.saturating_add(1);
			let range = matched.range();
			let start = matched.start_pos();
			let end = matched.end_pos();
			let meta_variables = if args.include_meta {
				Some(HashMap::<String, String>::from(matched.get_env().clone()))
			} else {
				None
			};
			all_matches.push(AstFindMatch {
				path: cand.display_path.clone(),
				text: matched.text().into_owned(),
				byte_start: to_u32(range.start),
				byte_end: to_u32(range.end),
				start_line: to_u32(start.line() + 1),
				start_column: to_u32(start.column(matched.get_node()) + 1),
				end_line: to_u32(end.line() + 1),
				end_column: to_u32(end.column(matched.get_node()) + 1),
				meta_variables,
			});
			files_with_matches.insert(cand.display_path.clone());
		}
	}

	all_matches.sort_by(|a, b| {
		a.path
			.cmp(&b.path)
			.then(a.start_line.cmp(&b.start_line))
			.then(a.start_column.cmp(&b.start_column))
			.then(a.end_line.cmp(&b.end_line))
			.then(a.end_column.cmp(&b.end_column))
			.then(a.byte_start.cmp(&b.byte_start))
			.then(a.byte_end.cmp(&b.byte_end))
	});

	let visible: Vec<AstFindMatch> = all_matches
		.into_iter()
		.skip(args.offset as usize)
		.collect();
	let limit_reached = visible.len() > args.limit as usize;
	let page: Vec<AstFindMatch> = visible.into_iter().take(args.limit as usize).collect();

	let mut file_match_counts: BTreeMap<String, u32> = BTreeMap::new();
	for m in &page {
		*file_match_counts.entry(m.path.clone()).or_insert(0) += 1;
	}

	let content = format_grep_text(&page, &file_match_counts, &parse_errors, limit_reached);
	let serialized: Vec<Value> = page.iter().map(|m| serde_json::to_value(m).unwrap()).collect();

	proto::emit(
		&content,
		json!({
			"matches": serialized,
			"totalMatches": total_matches,
			"filesWithMatches": files_with_matches.len() as u32,
			"filesSearched": files_searched,
			"limitReached": limit_reached,
			"parseErrors": if parse_errors.is_empty() { Value::Null } else { json!(parse_errors) },
		}),
	)
}

fn format_grep_text(
	matches: &[AstFindMatch],
	file_counts: &BTreeMap<String, u32>,
	parse_errors: &[String],
	limit_reached: bool,
) -> String {
	if matches.is_empty() {
		let mut out = String::from("No matches found");
		if !parse_errors.is_empty() {
			out.push_str(".\nParse issues:\n");
			for e in parse_errors.iter().take(20) {
				out.push_str("  - ");
				out.push_str(e);
				out.push('\n');
			}
			if parse_errors.len() > 20 {
				out.push_str(&format!("  ... {} more\n", parse_errors.len() - 20));
			}
		}
		return out;
	}
	let mut out = String::new();
	let mut current_file: Option<&str> = None;
	for m in matches {
		if current_file != Some(m.path.as_str()) {
			if current_file.is_some() {
				out.push('\n');
			}
			let count = file_counts.get(&m.path).copied().unwrap_or(0);
			out.push_str("# ");
			out.push_str(&m.path);
			out.push_str(&format!(" ({} match{})\n", count, if count == 1 { "" } else { "es" }));
			current_file = Some(m.path.as_str());
		}
		out.push_str(&format!(
			"  {}:{}  {}\n",
			m.start_line,
			m.start_column,
			truncate_for_display(&m.text, 200),
		));
		if let Some(meta) = &m.meta_variables {
			if !meta.is_empty() {
				let mut pairs: Vec<(&String, &String)> = meta.iter().collect();
				pairs.sort_by(|a, b| a.0.cmp(b.0));
				let serialized = pairs
					.iter()
					.map(|(k, v)| format!("{k}={v}"))
					.collect::<Vec<_>>()
					.join(", ");
				out.push_str(&format!("    meta: {serialized}\n"));
			}
		}
	}
	if limit_reached {
		out.push_str("\nResult limit reached; narrow paths or raise --limit.\n");
	}
	if !parse_errors.is_empty() {
		out.push_str("\nParse issues:\n");
		for e in parse_errors.iter().take(20) {
			out.push_str("  - ");
			out.push_str(e);
			out.push('\n');
		}
		if parse_errors.len() > 20 {
			out.push_str(&format!("  ... {} more\n", parse_errors.len() - 20));
		}
	}
	out
}

fn truncate_for_display(text: &str, max: usize) -> String {
	if text.chars().count() <= max {
		text.replace('\n', "\\n")
	} else {
		let mut out: String = text.chars().take(max - 1).collect();
		out.push('…');
		out.replace('\n', "\\n")
	}
}

// ─── ast-edit ──────────────────────────────────────────────────────────────

#[derive(ClapArgs, Debug)]
pub struct AstEditArgs {
	/// Rewrite rule in the form `pat=>out`. Repeat for multiple rules.
	#[arg(long = "op", required = true, num_args = 1.., action = clap::ArgAction::Append)]
	pub ops: Vec<String>,
	/// One or more files / directories. Repeat the flag for multiple targets.
	#[arg(long = "path", short = 'p', required = true, num_args = 1.., action = clap::ArgAction::Append)]
	pub paths: Vec<String>,
	/// Optional glob filter (relative to each search root).
	#[arg(long)]
	pub glob: Option<String>,
	/// Language override. Required when the search resolves to multiple languages.
	#[arg(long)]
	pub lang: Option<String>,
	/// Rule selector for contextual ast-grep patterns.
	#[arg(long)]
	pub selector: Option<String>,
	/// Match strictness: cst, smart (default), ast, relaxed, signature, template.
	#[arg(long, default_value = "smart")]
	pub strictness: String,
	/// Apply edits to disk (default: preview only).
	#[arg(long, default_value_t = false)]
	pub apply: bool,
	/// Cap on total replacements (all files).
	#[arg(long, default_value_t = DEFAULT_MAX_REPLACEMENTS)]
	pub max_replacements: u32,
	/// Cap on distinct files modified.
	#[arg(long, default_value_t = DEFAULT_MAX_FILES)]
	pub max_files: u32,
	/// Treat any parse error as fatal (default: collect and continue).
	#[arg(long, default_value_t = false)]
	pub fail_on_parse_error: bool,
}

#[derive(Serialize)]
struct AstReplaceChange {
	path: String,
	before: String,
	after: String,
	#[serde(rename = "byteStart")]
	byte_start: u32,
	#[serde(rename = "byteEnd")]
	byte_end: u32,
	#[serde(rename = "deletedLength")]
	deleted_length: u32,
	#[serde(rename = "startLine")]
	start_line: u32,
	#[serde(rename = "startColumn")]
	start_column: u32,
	#[serde(rename = "endLine")]
	end_line: u32,
	#[serde(rename = "endColumn")]
	end_column: u32,
}

#[derive(Serialize, Clone)]
struct AstReplaceFileChange {
	path: String,
	count: u32,
}

pub fn edit_run(args: AstEditArgs) -> anyhow::Result<()> {
	let rewrites = parse_op_rules(&args.ops)?;
	if rewrites.is_empty() {
		anyhow::bail!("`--op` is required (at least one `pat=>out` rule)");
	}
	let strictness = parse_strictness(&args.strictness)?;
	let dry_run = !args.apply;
	let max_replacements = args.max_replacements.max(1);
	let max_files = args.max_files.max(1);
	let explicit_lang = args.lang.as_deref().map(str::trim).filter(|v| !v.is_empty());

	let candidates = collect_candidates(&args.paths, args.glob.as_deref(), explicit_lang)?;
	let files_searched = candidates.len() as u32;

	// Determine the working language. For ast-edit, omp requires a single
	// language across all candidates when `--lang` is omitted: pattern
	// compilation is language-specific and a multi-language pass would need
	// per-file recompilation (slow + ambiguous).
	let effective_lang = if let Some(l) = explicit_lang {
		shared_ops::resolve_supported_lang(l)
			.map_err(|e| anyhow::anyhow!("{e}"))?
	} else {
		infer_single_lang(&candidates)?
	};

	let mut parse_errors: Vec<String> = Vec::new();
	let mut compiled_rules: Vec<(String, String, Pattern)> = Vec::new();
	for (pat, out) in &rewrites {
		match shared_ops::compile_pattern(pat, args.selector.as_deref(), &strictness, effective_lang) {
			Ok(c) => compiled_rules.push((pat.clone(), out.clone(), c)),
			Err(e) => {
				if args.fail_on_parse_error {
					anyhow::bail!("{}", e);
				}
				parse_errors.push(format!("{pat}: {e}"));
			}
		}
	}
	if compiled_rules.is_empty() {
		let content = if parse_errors.is_empty() {
			"No valid rewrite rules"
		} else {
			"All rewrite rules failed to compile"
		};
		return proto::emit(
			content,
			json!({
				"changes": [],
				"fileChanges": [],
				"totalReplacements": 0u32,
				"filesTouched": 0u32,
				"filesSearched": files_searched,
				"applied": !dry_run,
				"limitReached": false,
				"parseErrors": if parse_errors.is_empty() { Value::Null } else { json!(parse_errors) },
			}),
		);
	}

	let mut changes: Vec<AstReplaceChange> = Vec::new();
	let mut file_counts: BTreeMap<String, u32> = BTreeMap::new();
	let mut files_touched: u32 = 0;
	let mut limit_reached = false;

	'files: for cand in &candidates {
		// Skip files of a different language than the working language when
		// `--lang` was omitted (collect_candidates already filtered by
		// extension, but a mixed-language inference would have failed above).
		if cand.language.is_some() && cand.language != Some(effective_lang) {
			continue;
		}
		let source = match std::fs::read_to_string(&cand.absolute_path) {
			Ok(s) => s,
			Err(err) => {
				if args.fail_on_parse_error {
					anyhow::bail!("{}: {err}", cand.display_path);
				}
				parse_errors.push(format!("{}: {err}", cand.display_path));
				continue;
			}
		};
		let ast = effective_lang.ast_grep(&source);
		if ast.root().dfs().any(|node| node.is_error()) {
			let msg = format!(
				"{}: parse error (syntax tree contains error nodes)",
				cand.display_path
			);
			if args.fail_on_parse_error {
				anyhow::bail!("{msg}");
			}
			parse_errors.push(msg);
			continue;
		}
		let mut file_changes: Vec<(AstReplaceChange, Edit<String>)> = Vec::new();
		let mut reached_max = false;
		'rules: for (_pat, out, compiled) in &compiled_rules {
			for matched in ast.root().find_all(compiled.clone()) {
				if changes.len() + file_changes.len() >= max_replacements as usize {
					limit_reached = true;
					reached_max = true;
					break 'rules;
				}
				let edit = matched.replace_by(out.as_str());
				let range = matched.range();
				let start = matched.start_pos();
				let end = matched.end_pos();
				let after = String::from_utf8(edit.inserted_text.clone()).map_err(|err| {
					anyhow::anyhow!("{}: replacement text not valid UTF-8: {err}", cand.display_path)
				})?;
				file_changes.push((
					AstReplaceChange {
						path: cand.display_path.clone(),
						before: matched.text().into_owned(),
						after,
						byte_start: to_u32(range.start),
						byte_end: to_u32(range.end),
						deleted_length: to_u32(edit.deleted_length),
						start_line: to_u32(start.line() + 1),
						start_column: to_u32(start.column(matched.get_node()) + 1),
						end_line: to_u32(end.line() + 1),
						end_column: to_u32(end.column(matched.get_node()) + 1),
					},
					edit,
				));
			}
		}
		if file_changes.is_empty() {
			if reached_max {
				break 'files;
			}
			continue;
		}
		if files_touched >= max_files {
			limit_reached = true;
			break 'files;
		}
		files_touched = files_touched.saturating_add(1);
		file_counts.insert(cand.display_path.clone(), file_changes.len() as u32);

		if !dry_run {
			let edits: Vec<Edit<String>> = file_changes.iter().map(|e| Edit {
				position: e.1.position,
				deleted_length: e.1.deleted_length,
				inserted_text: e.1.inserted_text.clone(),
			}).collect();
			let written = shared_ops::apply_edits(&source, &edits)
				.map_err(|e| anyhow::anyhow!("{}: {e}", cand.display_path))?;
			if written != source {
				std::fs::write(&cand.absolute_path, written).map_err(|err| {
					anyhow::anyhow!("Failed to write {}: {err}", cand.display_path)
				})?;
			}
		}
		for (change, _) in file_changes {
			changes.push(change);
		}
		if reached_max {
			break 'files;
		}
	}

	let file_changes: Vec<AstReplaceFileChange> = file_counts
		.into_iter()
		.map(|(path, count)| AstReplaceFileChange { path, count })
		.collect();

	let content = format_edit_text(&changes, &file_changes, !dry_run, limit_reached, &parse_errors);
	let serialized_changes: Vec<Value> = changes.iter().map(|c| serde_json::to_value(c).unwrap()).collect();
	let serialized_file_changes: Vec<Value> =
		file_changes.iter().map(|c| serde_json::to_value(c).unwrap()).collect();

	proto::emit(
		&content,
		json!({
			"changes": serialized_changes,
			"fileChanges": serialized_file_changes,
			"totalReplacements": changes.len() as u32,
			"filesTouched": files_touched,
			"filesSearched": files_searched,
			"applied": !dry_run,
			"limitReached": limit_reached,
			"parseErrors": if parse_errors.is_empty() { Value::Null } else { json!(parse_errors) },
		}),
	)
}

fn format_edit_text(
	changes: &[AstReplaceChange],
	file_changes: &[AstReplaceFileChange],
	applied: bool,
	limit_reached: bool,
	parse_errors: &[String],
) -> String {
	if changes.is_empty() {
		let mut out = String::from("No replacements made");
		if !parse_errors.is_empty() {
			out.push_str("\nParse issues:\n");
			for e in parse_errors.iter().take(20) {
				out.push_str("  - ");
				out.push_str(e);
				out.push('\n');
			}
		}
		return out;
	}
	let mut out = String::new();
	let header = if applied { "Applied" } else { "Preview" };
	let total: u32 = file_changes.iter().map(|f| f.count).sum();
	out.push_str(&format!(
		"{header}: {} replacement{} across {} file{}.\n",
		total,
		if total == 1 { "" } else { "s" },
		file_changes.len(),
		if file_changes.len() == 1 { "" } else { "s" },
	));
	let mut current_file: Option<&str> = None;
	let mut file_count_map: BTreeMap<&str, u32> = BTreeMap::new();
	for fc in file_changes {
		file_count_map.insert(fc.path.as_str(), fc.count);
	}
	for change in changes {
		if current_file != Some(change.path.as_str()) {
			if current_file.is_some() {
				out.push('\n');
			}
			let count = file_count_map.get(change.path.as_str()).copied().unwrap_or(0);
			out.push_str("# ");
			out.push_str(&change.path);
			out.push_str(&format!(" ({} replacement{})\n", count, if count == 1 { "" } else { "s" }));
			current_file = Some(change.path.as_str());
		}
		let before = truncate_for_display(&change.before, 120);
		let after = truncate_for_display(&change.after, 120);
		out.push_str(&format!("- {}:{}  {}\n", change.start_line, change.start_column, before));
		out.push_str(&format!("+ {}:{}  {}\n", change.start_line, change.start_column, after));
	}
	if limit_reached {
		out.push_str("\nLimit reached; narrow paths or raise --max-replacements / --max-files.\n");
	}
	if !parse_errors.is_empty() {
		out.push_str("\nParse issues:\n");
		for e in parse_errors.iter().take(20) {
			out.push_str("  - ");
			out.push_str(e);
			out.push('\n');
		}
		if parse_errors.len() > 20 {
			out.push_str(&format!("  ... {} more\n", parse_errors.len() - 20));
		}
	}
	out
}

// ─── shared helpers ────────────────────────────────────────────────────────

struct Candidate {
	absolute_path: PathBuf,
	display_path: String,
	language: Option<SupportLang>,
}

fn collect_candidates(
	paths: &[String],
	glob: Option<&str>,
	explicit_lang: Option<&str>,
) -> anyhow::Result<Vec<Candidate>> {
	let glob_set = compile_globset(glob)?;
	let mut out: Vec<Candidate> = Vec::new();

	for path_str in paths {
		let root = PathBuf::from(path_str);
		let md = match std::fs::metadata(&root) {
			Ok(m) => m,
			Err(_) => continue,
		};
		if md.is_file() {
			if let Some(c) = make_candidate(&root, &root, explicit_lang, glob_set.as_ref())? {
				out.push(c);
			}
			continue;
		}
		if !md.is_dir() {
			continue;
		}
		let walker = WalkBuilder::new(&root)
			.hidden(false)
			.git_ignore(true)
			.git_global(true)
			.git_exclude(true)
			.build();
		for entry in walker.filter_map(|e| e.ok()) {
			if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
				continue;
			}
			let abs = entry.into_path();
			if let Some(c) = make_candidate(&abs, &root, explicit_lang, glob_set.as_ref())? {
				out.push(c);
			}
		}
	}

	out.sort_by(|a, b| a.display_path.cmp(&b.display_path));
	Ok(out)
}

fn make_candidate(
	abs: &Path,
	base: &Path,
	explicit_lang: Option<&str>,
	glob_set: Option<&GlobSet>,
) -> anyhow::Result<Option<Candidate>> {
	if !shared_ops::is_supported_file(abs, explicit_lang) {
		return Ok(None);
	}
	// When the caller passed a single file (base == abs), strip_prefix gives
	// the empty path; fall back to the file's basename for display.
	let rel = abs.strip_prefix(base).unwrap_or(abs);
	let display = if rel.as_os_str().is_empty() {
		abs.file_name()
			.map(|n| n.to_string_lossy().into_owned())
			.unwrap_or_else(|| abs.to_string_lossy().into_owned())
	} else {
		rel.to_string_lossy().replace('\\', "/")
	};
	if let Some(g) = glob_set {
		if !g.is_match(&display) {
			return Ok(None);
		}
	}
	let language = if let Some(l) = explicit_lang {
		Some(shared_ops::resolve_supported_lang(l).map_err(|e| anyhow::anyhow!("{e}"))?)
	} else {
		shared_ops::resolve_language(None, abs).ok()
	};
	Ok(Some(Candidate {
		absolute_path: abs.to_path_buf(),
		display_path: display,
		language,
	}))
}

fn infer_single_lang(candidates: &[Candidate]) -> anyhow::Result<SupportLang> {
	let mut langs: BTreeSet<&'static str> = BTreeSet::new();
	let mut first: Option<SupportLang> = None;
	for c in candidates {
		if let Some(l) = c.language {
			if langs.insert(l.canonical_name()) {
				if first.is_none() {
					first = Some(l);
				}
			}
		}
	}
	match langs.len() {
		0 => anyhow::bail!(
			"`--lang` is required for ast-edit when no candidate files have a recognizable extension"
		),
		1 => Ok(first.expect("non-empty inferred set")),
		_ => anyhow::bail!(
			"`--lang` is required for ast-edit when path/glob resolves to multiple languages: {}",
			langs.into_iter().collect::<Vec<_>>().join(", ")
		),
	}
}

fn compile_globset(glob: Option<&str>) -> anyhow::Result<Option<GlobSet>> {
	let g = match glob {
		Some(s) if !s.trim().is_empty() => s.trim(),
		_ => return Ok(None),
	};
	let mut builder = GlobSetBuilder::new();
	let compiled = Glob::new(g).map_err(|e| anyhow::anyhow!("invalid glob `{g}`: {e}"))?;
	builder.add(compiled);
	let set = builder.build().map_err(|e| anyhow::anyhow!("globset build: {e}"))?;
	Ok(Some(set))
}

fn parse_strictness(value: &str) -> anyhow::Result<MatchStrictness> {
	let v = value.trim().to_ascii_lowercase();
	Ok(match v.as_str() {
		"cst" => MatchStrictness::Cst,
		"smart" | "" => MatchStrictness::Smart,
		"ast" => MatchStrictness::Ast,
		"relaxed" => MatchStrictness::Relaxed,
		"signature" => MatchStrictness::Signature,
		"template" => MatchStrictness::Template,
		other => anyhow::bail!(
			"Unknown strictness `{other}` (cst, smart, ast, relaxed, signature, template)"
		),
	})
}

fn parse_op_rules(ops: &[String]) -> anyhow::Result<Vec<(String, String)>> {
	let mut seen: BTreeSet<String> = BTreeSet::new();
	let mut out: Vec<(String, String)> = Vec::new();
	for raw in ops {
		let raw = raw.trim();
		if raw.is_empty() {
			anyhow::bail!("Empty --op value");
		}
		let (pat, out_text) = raw
			.split_once("=>")
			.ok_or_else(|| anyhow::anyhow!("--op `{raw}` must be in the form `pat=>out`"))?;
		let pat = pat.trim().to_string();
		let out_text = out_text.trim_start().to_string();
		if pat.is_empty() {
			anyhow::bail!("--op pattern must be non-empty");
		}
		if !seen.insert(pat.clone()) {
			anyhow::bail!("Duplicate rewrite pattern: {pat}");
		}
		out.push((pat, out_text));
	}
	Ok(out)
}

fn to_u32(value: usize) -> u32 {
	value.min(u32::MAX as usize) as u32
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn parse_op_rule_simple() {
		let ops = vec!["foo($X)=>bar($X)".to_string()];
		let parsed = parse_op_rules(&ops).expect("parse should succeed");
		assert_eq!(parsed.len(), 1);
		assert_eq!(parsed[0].0, "foo($X)");
		assert_eq!(parsed[0].1, "bar($X)");
	}

	#[test]
	fn parse_op_rule_missing_separator_errors() {
		let ops = vec!["foo".to_string()];
		assert!(parse_op_rules(&ops).is_err());
	}

	#[test]
	fn parse_op_rule_duplicate_errors() {
		let ops = vec!["foo=>bar".to_string(), "foo=>baz".to_string()];
		assert!(parse_op_rules(&ops).is_err());
	}

	#[test]
	fn strictness_aliases() {
		assert!(matches!(parse_strictness("smart").unwrap(), MatchStrictness::Smart));
		assert!(matches!(parse_strictness("AST").unwrap(), MatchStrictness::Ast));
		assert!(parse_strictness("brainfuck").is_err());
	}
}
