//! Git output compression with explicit formats and global arguments preserved.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered, run_passthrough};

#[derive(Args, Debug)]
pub struct GitArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: GitArgs) -> anyhow::Result<()> {
    let (argv, compact) = prepare(args.args);
    let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
    let code = if compact {
        let hint = format!("git_{}", refs[0]);
        run_filtered("git", &refs, &hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?
    } else {
        run_passthrough("git", &refs)?
    };
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}

fn prepare(mut args: Vec<String>) -> (Vec<String>, bool) {
    let Some(subcommand) = args.first().map(String::as_str) else {
        return (args, false);
    };
    // Global options such as -C/-c and other subcommands retain native Git
    // behavior. Machine-readable formats are output contracts, not summaries.
    if !matches!(subcommand, "status" | "diff" | "log" | "show") {
        return (args, false);
    }
    if args.iter().any(|arg| {
        matches!(
            arg.as_str(),
            "-z" | "--null" | "--binary" | "--numstat" | "--raw"
        ) || [
            "--porcelain",
            "--format",
            "--pretty",
            "--output",
            "--name-only",
            "--name-status",
        ]
        .iter()
        .any(|flag| arg == flag || arg.strip_prefix(flag).is_some_and(|s| s.starts_with('=')))
    }) || (subcommand == "show"
        && args
            .iter()
            .skip(1)
            .any(|arg| !arg.starts_with('-') && arg.contains(':')))
    {
        return (args, false);
    }
    if subcommand == "status" {
        let has_format = args.iter().skip(1).any(|arg| {
            matches!(arg.as_str(), "--short" | "--long")
                || (arg.starts_with('-') && !arg.starts_with("--") && arg.contains('s'))
        });
        if !has_format {
            args.insert(1, "--short".into());
        }
    }
    (args, true)
}

/// Keep patch metadata and every changed line; omit only unchanged context.
/// The shared recovery guard retains the exact patch before this transform.
pub fn summarize(text: &str, args: &[&str]) -> String {
    if !matches!(args.first(), Some(&"diff" | &"show")) || !text.contains("diff --git ") {
        return text.to_owned();
    }
    let mut patch = false;
    let mut out = String::from("[patch summary; unchanged context and blob IDs omitted]\n");
    let lines: Vec<_> = text.split_inclusive('\n').collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if line.starts_with("diff --git ") {
            patch = false;
        }
        if line.starts_with("@@") {
            patch = true;
        }
        if line.starts_with("index ") || (patch && line.starts_with(' ')) {
            i += 1;
            continue;
        }
        if patch && line.starts_with('-') {
            let start = i;
            while i < lines.len() && lines[i].starts_with('-') {
                i += 1;
            }
            let mid = i;
            while i < lines.len() && lines[i].starts_with('+') {
                i += 1;
            }
            let paired = mid - start == i - mid
                && (0..mid - start).all(|j| {
                    match (
                        lines[start + j][1..].split_once('='),
                        lines[mid + j][1..].split_once('='),
                    ) {
                        (Some((a, _)), Some((b, _))) => a == b,
                        _ => false,
                    }
                });
            if paired {
                for j in 0..mid - start {
                    let old = lines[start + j][1..].trim_end().split_once('=').unwrap().1;
                    out.push_str(&format!("{} [was {old}]\n", lines[mid + j].trim_end()));
                }
            } else {
                for line in &lines[start..i] {
                    out.push_str(line);
                }
            }
            continue;
        }
        out.push_str(line);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prepare_args(args: &[&str]) -> (Vec<String>, bool) {
        prepare(args.iter().map(|arg| (*arg).to_string()).collect())
    }

    #[test]
    fn adds_defaults_only_for_human_output() {
        assert_eq!(prepare_args(&["status"]).0, ["status", "--short"]);
        assert_eq!(prepare_args(&["status", "-sb"]).0, ["status", "-sb"]);
        assert_eq!(prepare_args(&["log", "-n5"]).0, ["log", "-n5"]);
        assert_eq!(prepare_args(&["log", "-5"]).0, ["log", "-5"]);
    }

    #[test]
    fn explicit_formats_and_global_options_are_verbatim() {
        for args in [
            vec!["status", "--porcelain=v2"],
            vec!["log", "--format=%H"],
            vec!["log", "--pretty=raw"],
            vec!["diff", "--numstat", "-z"],
            vec!["show", "HEAD:path/to/file"],
            vec!["-C", "/tmp/repo", "status"],
            vec!["rev-parse", "HEAD"],
        ] {
            let (actual, compact) = prepare_args(&args);
            assert!(!compact, "{args:?}");
            assert_eq!(actual, args);
        }
    }
}
