//! Exercise the real CLI boundary: output bytes, exit status, and recovery.
#![cfg(unix)]

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

// On Unix, a concurrent spawn can briefly inherit another test's writable
// script descriptor before exec closes it, making that script ETXTBSY. Keep
// fixture creation and child launches serialized; production concurrency is
// tested separately by the recovery module's scoped threads.
static CLI_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn pi(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_pi-rs"));
    command
        .current_dir(dir)
        .env("XDG_DATA_HOME", dir.join("data"));
    command
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null");
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    command
}

fn fake_cargo(dir: &Path, script: &str) -> Command {
    fake_tool(dir, "cargo", script)
}

fn fake_tool(dir: &Path, program: &str, script: &str) -> Command {
    let search_path = std::env::var_os("PATH").unwrap();
    let shell = std::env::split_paths(&search_path)
        .map(|entry| entry.join("sh"))
        .find(|entry| entry.is_file())
        .expect("sh on PATH");
    let bin = dir.join(program);
    fs::write(&bin, format!("#!{}\n{script}\n", shell.display())).unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::join_paths(
        std::iter::once(dir.to_path_buf()).chain(std::env::split_paths(&search_path)),
    )
    .unwrap();
    let mut command = pi(dir);
    command.env("PATH", path).arg(program);
    command
}

fn with_input(mut command: Command, input: &[u8]) -> Output {
    let mut child = command.stdin(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    child.wait_with_output().unwrap()
}

const DIAGNOSTICS: &str = r"i=0; while [ $i -lt 300 ]; do printf '\033[31mRepeated diagnostic with context\033[0m\n'; i=$((i+1)); done; printf 'fatal: the operation failed\n' >&2; exit 42";

fn raw_diagnostics() -> String {
    "\x1b[31mRepeated diagnostic with context\x1b[0m\n".repeat(300)
        + "fatal: the operation failed\n"
}

#[test]
fn failed_command_keeps_its_status_and_a_complete_recovery_file() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let output = fake_cargo(tmp.path(), DIAGNOSTICS)
        .arg("test")
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(42),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let shown = String::from_utf8(output.stdout).unwrap();
    assert!(shown.contains("fatal: the operation failed"));
    let path = shown
        .split("[full output: ")
        .nth(1)
        .unwrap()
        .split(']')
        .next()
        .unwrap();
    let recovered = pi(tmp.path())
        .args(["read", "--no-truncate", path])
        .output()
        .unwrap();
    assert!(recovered.status.success());
    assert_eq!(recovered.stdout, raw_diagnostics().as_bytes());
    assert!(shown.len() < raw_diagnostics().len());
}

#[test]
fn recovery_failure_keeps_the_full_output_and_the_original_failure() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("data"), "not a directory").unwrap();
    let output = fake_cargo(tmp.path(), DIAGNOSTICS)
        .arg("test")
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(42),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8(output.stdout).unwrap(), raw_diagnostics());
}

#[test]
fn explicit_machine_formats_preserve_stdin_stdout_and_stderr_bytes() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    for (program, args) in [
        ("cargo", vec!["--message-format=json"]),
        ("kubectl", vec!["get", "pods", "-o", "json"]),
        ("kubectl", vec!["get", "pods", "--output=yaml"]),
    ] {
        let mut command = fake_tool(tmp.path(), program, "cat; printf 'stderr only\n' >&2");
        command.args(args);
        let input = b"same\nsame\n\x00\xff\n";
        let output = with_input(command, input);
        assert!(output.status.success());
        assert_eq!(output.stdout, input);
        assert_eq!(output.stderr, b"stderr only\n");
    }
}

#[test]
fn signals_propagate_as_shell_exit_codes() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let output = fake_cargo(tmp.path(), "kill -TERM $$")
        .arg("test")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(143));
}

fn git(dir: &Path, args: &[&str]) -> Output {
    Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn git_global_options_and_explicit_formats_match_git() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    assert!(git(tmp.path(), &["init", "--quiet"]).status.success());
    fs::write(tmp.path().join("file with spaces"), "initial\n").unwrap();
    assert!(git(tmp.path(), &["add", "."]).status.success());
    assert!(
        git(
            tmp.path(),
            &[
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "--quiet",
                "-m",
                "first"
            ]
        )
        .status
        .success()
    );
    for args in [
        vec!["status", "--porcelain=v2", "-z"],
        vec!["log", "--format=%H%x00%s"],
        vec!["show", "HEAD:file with spaces"],
        vec!["-C", tmp.path().to_str().unwrap(), "rev-parse", "HEAD"],
    ] {
        let actual = pi(tmp.path()).arg("git").args(&args).output().unwrap();
        let expected = git(tmp.path(), &args);
        assert_eq!(actual.status.code(), expected.status.code());
        assert_eq!(actual.stdout, expected.stdout, "{args:?}");
        assert_eq!(actual.stderr, expected.stderr, "{args:?}");
    }
}

#[test]
fn recovery_logs_can_be_read_without_truncating_again() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let source = "diagnostic\n".repeat(1000);
    let path: PathBuf = tmp.path().join("long.log");
    fs::write(&path, &source).unwrap();
    let output = pi(tmp.path())
        .args(["read", "--no-truncate"])
        .arg(path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(output.stdout, source.as_bytes());
}

#[test]
fn html_conversion_keeps_content_and_respects_image_option() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let mut command = pi(tmp.path());
    command.args(["html2md", "--no-clean", "--skip-images"]);
    let output = with_input(
        command,
        b"<h1>Title</h1><p>Keep <strong>this</strong>.</p><img src='photo.png' alt='photo'>",
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let markdown = String::from_utf8(output.stdout).unwrap();
    assert!(markdown.contains("# Title"));
    assert!(markdown.contains("**this**"));
    assert!(!markdown.contains("photo.png"));
}

fn stdout(output: Output) -> String {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn search_literal_unicode_context_and_plain_extension_protocol() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("unicode.txt");
    fs::write(&source, "outside\nbefore\nπ.a\nπ.a again\nafter\nend\n").unwrap();
    let plain = stdout(
        pi(tmp.path())
            .args(["grep", "-F", "-e", "π.a", "-p", "unicode.txt", "-C", "1"])
            .output()
            .unwrap(),
    );
    assert_eq!(plain, "2-before\n3:π.a\n4:π.a again\n5-after\n");
    let default = stdout(
        pi(tmp.path())
            .args(["grep", "-F", "-e", "π.a", "-p", "unicode.txt"])
            .output()
            .unwrap(),
    );
    assert_eq!(default, "3:π.a\n4:π.a again\n");
    let json = stdout(
        pi(tmp.path())
            .args(["grep", "--json", "-F", "-e", "π.a", "-p", "unicode.txt"])
            .output()
            .unwrap(),
    );
    let json: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(json["details"]["matchCount"], 2);
    assert!(json["content"].as_str().unwrap().starts_with("*3"));
    assert!(
        stdout(
            pi(tmp.path())
                .args(["grep", "-e", "π", "-p", "unicode.txt"])
                .output()
                .unwrap()
        )
        .contains("π.a")
    );
}

#[test]
fn search_pages_reach_all_matches_beyond_the_old_per_file_cap() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    for name in ["a", "b"] {
        fs::write(
            tmp.path().join(name),
            (0..57)
                .map(|i| format!("hit-{name}-{i}\n"))
                .collect::<String>(),
        )
        .unwrap();
    }
    let mut seen = std::collections::BTreeSet::new();
    for skip in (0..114).step_by(11) {
        let shown = stdout(
            pi(tmp.path())
                .args([
                    "grep",
                    "--json",
                    "-e",
                    "hit-",
                    "-p",
                    "a",
                    "b",
                    "--limit",
                    "11",
                    "--skip",
                    &skip.to_string(),
                ])
                .output()
                .unwrap(),
        );
        let value: serde_json::Value = serde_json::from_str(&shown).unwrap();
        let content = value["content"].as_str().unwrap();
        assert_eq!(value["details"]["totalMatches"], 114);
        for line in content.lines().filter(|l| l.starts_with('*')) {
            assert!(
                seen.insert(line.split_once('|').unwrap().1.to_string()),
                "duplicate match"
            );
        }
        if skip < 110 {
            assert!(content.contains("continue with --skip"));
        }
    }
    assert_eq!(seen.len(), 114);
}

#[test]
fn read_byte_budget_targeted_recovery_and_no_small_file_truncation() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let medium = (0..500)
        .map(|i| format!("setting_{i}=enabled\n"))
        .collect::<String>();
    fs::write(tmp.path().join("medium"), &medium).unwrap();
    assert_eq!(
        stdout(pi(tmp.path()).args(["read", "medium"]).output().unwrap()),
        medium
    );
    let large = (0..3000)
        .map(|i| format!("line_{i}: λ🙂{}\n", "payload".repeat(20)))
        .collect::<String>();
    fs::write(tmp.path().join("large"), &large).unwrap();
    let shown = stdout(
        pi(tmp.path())
            .args(["--max-output-bytes", "512", "read", "large"])
            .output()
            .unwrap(),
    );
    assert!(shown.len() <= 512);
    let recovery = shown
        .split("full output: ")
        .nth(1)
        .unwrap()
        .split(']')
        .next()
        .unwrap();
    let selected = stdout(
        pi(tmp.path())
            .args(["recall", recovery, "--grep", "line_1500:", "-F", "-n"])
            .output()
            .unwrap(),
    );
    assert!(selected.starts_with("1501:line_1500:"));
    assert_eq!(
        stdout(
            pi(tmp.path())
                .args(["recall", recovery, "--full"])
                .output()
                .unwrap()
        ),
        large
    );
    assert_eq!(
        pi(tmp.path())
            .args(["read", "large", "--grep", "ABSENT"])
            .output()
            .unwrap()
            .status
            .code(),
        Some(1)
    );
}

#[test]
fn logs_group_timestamps_preserve_diagnostics_identifiers_and_long_line_labels() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let mut raw = String::new();
    for i in 0..3000 {
        raw.push_str(&format!(
            "2026-10-09T10:{:02}:{:02}Z INFO heartbeat sequence={i:04}\n",
            i / 60,
            i % 60
        ));
        if i == 1500 {
            raw.push_str("WARN request_id=ABC stalled\nERROR request_id=XYZ failed\nunknown plugin diagnostic\n");
        }
    }
    for i in 0..10 {
        raw.push_str(&format!(
            "line={i:02} {}\n",
            "payload=abcdefgh ".repeat(900)
        ));
    }
    fs::write(tmp.path().join("log"), &raw).unwrap();
    let shown = stdout(pi(tmp.path()).args(["log", "log"]).output().unwrap());
    assert!(shown.len() < 2500, "{} bytes", shown.len());
    for fact in ["ABC", "XYZ", "unknown plugin diagnostic", "line=05"] {
        assert!(shown.contains(fact), "{fact}");
    }
    let path = shown
        .split("full output: ")
        .nth(1)
        .unwrap()
        .split(']')
        .next()
        .unwrap();
    assert_eq!(
        stdout(
            pi(tmp.path())
                .args(["read", path, "--full"])
                .output()
                .unwrap()
        ),
        raw
    );
}

#[test]
fn json_exposes_middle_exceptions_shapes_and_exact_pointer_filters() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let records: Vec<_> = (0..500).map(|i| serde_json::json!({"id": i, "status": if i == 250 {"failed"} else {"ready"}, "message": format!("record-{i:03}")})).collect();
    let raw = serde_json::to_string_pretty(&serde_json::json!({"records": records, "total": 500}))
        .unwrap();
    fs::write(tmp.path().join("response"), &raw).unwrap();
    let shown = stdout(pi(tmp.path()).args(["json", "response"]).output().unwrap());
    assert!(shown.contains("record-250"));
    assert!(shown.contains("total: 500"));
    assert!(shown.contains("omitted"));
    let recovery = shown
        .split("full output: ")
        .nth(1)
        .unwrap()
        .split(']')
        .next()
        .unwrap();
    assert_eq!(
        stdout(
            pi(tmp.path())
                .args(["read", recovery, "--full"])
                .output()
                .unwrap()
        ),
        raw
    );
    for args in [
        vec!["--pointer", "/records/250"],
        vec!["--pointer", "/records", "--where", "/status=\"failed\""],
    ] {
        let selected = stdout(
            pi(tmp.path())
                .args(["json", "response"])
                .args(args)
                .output()
                .unwrap(),
        );
        assert!(selected.contains("record-250"));
        assert!(!selected.contains("record-249"));
    }
    fs::write(
        tmp.path().join("heterogeneous"),
        "[{\"a\":1}, {\"a\":true,\"late\":null}, [\"x\"]]",
    )
    .unwrap();
    let structure = stdout(
        pi(tmp.path())
            .args(["json", "heterogeneous", "--structure"])
            .output()
            .unwrap(),
    );
    for fact in ["late", "bool", "null", "string"] {
        assert!(structure.contains(fact), "{structure}");
    }
}

#[test]
fn explicit_stream_has_native_arguments_and_immediate_first_byte() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    use std::{
        io::Read,
        time::{Duration, Instant},
    };
    let tmp = tempfile::tempdir().unwrap();
    // Install a fake git without launching it, then put --stream before it.
    let fake = fake_tool(
        tmp.path(),
        "git",
        "printf 'ARG:%s\n' \"$@\"; sleep 1; printf 'done\n' >&2",
    );
    let path = fake
        .get_envs()
        .find(|(k, _)| *k == "PATH")
        .unwrap()
        .1
        .unwrap()
        .to_os_string();
    let start = Instant::now();
    let mut child = pi(tmp.path())
        .env("PATH", path)
        .args(["--stream", "git", "log"])
        .spawn()
        .unwrap();
    let mut first = [0; 1];
    child
        .stdout
        .as_mut()
        .unwrap()
        .read_exact(&mut first)
        .unwrap();
    assert!(
        start.elapsed() < Duration::from_millis(800),
        "stream buffered until completion"
    );
    assert_eq!(&first, b"A");
    let rest = child.wait_with_output().unwrap();
    assert_eq!(rest.stdout, b"RG:log\n");
    assert_eq!(rest.stderr, b"done\n");
    assert!(
        !pi(tmp.path())
            .args(["--stream", "read", "git"])
            .output()
            .unwrap()
            .status
            .success()
    );
}

#[test]
fn automatic_follow_and_interactive_passthrough_preserve_arguments_and_bytes() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    for (tool, args) in [
        ("docker", vec!["logs", "--follow", "container"]),
        ("kubectl", vec!["get", "pods", "-w"]),
        ("pytest", vec!["--pdb"]),
    ] {
        let mut command = fake_tool(tmp.path(), tool, "printf '%s\n' \"$@\" >&2; cat");
        command.args(&args);
        let input = b"\xff\0\nline\n";
        let output = with_input(command, input);
        assert!(output.status.success());
        assert_eq!(output.stdout, input);
        assert_eq!(
            String::from_utf8(output.stderr).unwrap(),
            args.join("\n") + "\n"
        );
    }
}

#[test]
fn captured_stdout_stderr_chronology_and_unknown_output_are_preserved() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let script = "printf 'out1\n'; printf 'err1\n' >&2; printf 'out2\n'; printf 'err2\n' >&2";
    let shown = stdout(fake_cargo(tmp.path(), script).arg("test").output().unwrap());
    assert_eq!(shown, "out1\nerr1\nout2\nerr2\n");
    let mut cmd = fake_cargo(tmp.path(), "cat");
    cmd.arg("test");
    assert_eq!(with_input(cmd, b"\xff\0raw\n").stdout, b"\xff\0raw\n");
}

#[test]
fn cargo_summary_keeps_failure_blocks_warnings_and_unknown_formats() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let script = "i=0; while [ $i -lt 300 ]; do printf 'test suite::test_%s ... ok\n' $i; i=$((i+1)); done; printf 'warning: suspicious thing\nUNKNOWN plugin format\nfailures:\n---- broken stdout ----\nassertion failed: left 7 right 9\ntest result: FAILED. 300 passed; 1 failed\n'; exit 101";
    let output = fake_cargo(tmp.path(), script).arg("test").output().unwrap();
    assert_eq!(
        output.status.code(),
        Some(101),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let shown = String::from_utf8(output.stdout).unwrap();
    for fact in [
        "warning: suspicious thing",
        "UNKNOWN plugin format",
        "left 7 right 9",
        "300 passed; 1 failed",
    ] {
        assert!(shown.contains(fact));
    }
    assert!(!shown.contains("test_150 ... ok"));
}

#[test]
fn git_default_history_retains_author_and_depth_past_twenty() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    assert!(git(tmp.path(), &["init", "-q"]).status.success());
    for i in 0..25 {
        assert!(
            git(
                tmp.path(),
                &[
                    "-c",
                    "user.name=History Author",
                    "-c",
                    "user.email=history@example.invalid",
                    "commit",
                    "--allow-empty",
                    "-qm",
                    &format!("revision-{i:02}")
                ]
            )
            .status
            .success()
        );
    }
    let shown = stdout(pi(tmp.path()).args(["git", "log"]).output().unwrap());
    for fact in ["History Author", "revision-00", "revision-24"] {
        assert!(shown.contains(fact));
    }
}

#[test]
fn small_listings_match_native_and_empty_directories_emit_nothing() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let empty = stdout(pi(tmp.path()).arg("ls").output().unwrap());
    assert!(empty.is_empty());
    for name in ["a", "z", ".hidden"] {
        fs::write(tmp.path().join(name), "").unwrap();
    }
    fs::create_dir(tmp.path().join("sub")).unwrap();
    assert_eq!(
        stdout(pi(tmp.path()).arg("ls").output().unwrap()),
        "a\nsub\nz\n"
    );
    assert_eq!(
        stdout(pi(tmp.path()).args(["ls", "--all"]).output().unwrap()),
        ".hidden\na\nsub\nz\n"
    );
}

#[test]
fn native_help_flags_are_forwarded_through_wrappers() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    for program in ["git", "cargo", "pytest", "docker"] {
        let shown = stdout(
            fake_tool(tmp.path(), program, "printf 'native:%s\n' \"$@\"")
                .arg("--help")
                .output()
                .unwrap(),
        );
        assert_eq!(shown, "native:--help\n");
    }
}

#[test]
fn huge_key_value_diff_keeps_the_central_unsafe_change_and_original_patch() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    assert!(git(tmp.path(), &["init", "-q"]).status.success());
    let original = (0..600)
        .map(|i| format!("option_{i:03}=safe\n"))
        .collect::<String>();
    fs::write(tmp.path().join("config"), &original).unwrap();
    assert!(git(tmp.path(), &["add", "."]).status.success());
    assert!(
        git(
            tmp.path(),
            &[
                "-c",
                "user.name=T",
                "-c",
                "user.email=t@example.invalid",
                "commit",
                "-qm",
                "initial"
            ]
        )
        .status
        .success()
    );
    let changed = (0..600)
        .map(|i| {
            format!(
                "option_{i:03}={}\n",
                if i == 300 { "unsafe" } else { "changed" }
            )
        })
        .collect::<String>();
    fs::write(tmp.path().join("config"), changed).unwrap();
    let raw = git(tmp.path(), &["diff"]).stdout;
    let shown = stdout(pi(tmp.path()).args(["git", "diff"]).output().unwrap());
    assert!(shown.contains("option_300=unsafe [was safe]"));
    let recovery = shown
        .split("full output: ")
        .nth(1)
        .unwrap()
        .split(']')
        .next()
        .unwrap();
    assert_eq!(
        pi(tmp.path())
            .args(["read", recovery, "--full"])
            .output()
            .unwrap()
            .stdout,
        raw
    );
}

#[test]
fn sql_ast_works_with_the_updated_cc_build_library() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    fs::write(
        tmp.path().join("query.sql"),
        "SELECT id, name FROM users WHERE active = true;\n",
    )
    .unwrap();
    let output = stdout(
        pi(tmp.path())
            .args(["summary", "query.sql", "--json"])
            .output()
            .unwrap(),
    );
    let value: serde_json::Value = serde_json::from_str(&output).unwrap();
    assert_eq!(value["details"]["parsed"], true);
    assert!(value["content"].as_str().unwrap().contains("SELECT"));
}

#[test]
fn pytest_summary_omits_known_banner_but_keeps_warnings_and_unknown_plugins() {
    let _serial = CLI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = tempfile::tempdir().unwrap();
    let script = "printf '================ test session starts ================\nplatform linux -- Python 3, pytest-9\nrootdir: /fixture\ncollected 100 items\ncustom plugin diagnostic\n'; i=0; while [ $i -lt 100 ]; do printf 'test_x.py::test_%s PASSED [100%%]\n' $i; i=$((i+1)); done; printf '================ warnings summary ================\nwarning: deprecated API at api.py:12\n================ 100 passed, 1 warning in 0.1s ================\n'";
    let shown = stdout(fake_tool(tmp.path(), "pytest", script).output().unwrap());
    assert!(!shown.contains("test session starts"));
    assert!(!shown.contains("test_50 PASSED"));
    for fact in [
        "custom plugin diagnostic",
        "deprecated API at api.py:12",
        "100 passed, 1 warning",
    ] {
        assert!(shown.contains(fact), "{shown}");
    }
    assert!(shown.contains("full output:"));
}
