#!/usr/bin/env python3
"""Paired command benchmark. See README.md for scope and reproduction.

All children use argv subprocesses, bypassing shell rewrite hooks. Timing runs
are serial and order-randomized. Tokenization and evidence writes are untimed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tarfile
import time

import tiktoken

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CODEX_COMMIT = "c1382380de69521303b416720a52f42d51af6248"
SOURCE_FILES = [
    "codex-rs/utils/string/src/truncate.rs",
    "codex-rs/utils/output-truncation/src/lib.rs",
    "codex-rs/core/src/unified_exec/mod.rs",
    "codex-rs/core/src/tools/context.rs",
]
ENCODERS = {n: tiktoken.get_encoding(n) for n in ["o200k_base", "cl100k_base"]}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tokens(text):
    return {n: len(e.encode(text, disallowed_special=())) for n, e in ENCODERS.items()}


def run(argv, cwd, env):
    start = time.perf_counter_ns()
    p = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=180)
    elapsed = (time.perf_counter_ns() - start) / 1e6
    # Match pi-rs's non-PTY combination for completed command payloads.
    output = p.stdout
    if p.stderr:
        output += (b"\n" if output and not output.endswith(b"\n") else b"") + p.stderr
    return output.decode("utf-8", errors="replace"), p.returncode, elapsed


def checked(argv, cwd, env):
    output, code, _ = run(argv, cwd, env)
    if code:
        raise RuntimeError(f"{argv!r}: {code}\n{output[:2000]}")
    return output


def prepare(work, env):
    work.mkdir(parents=True, exist_ok=False)
    with tarfile.open(HERE / "source-snapshot.tar.gz") as tar:
        tar.extractall(work / "source", filter="data")
    git = shutil.which("git")
    for name, changed in [("git-small", 8), ("git-many", 100)]:
        repo = work / name
        repo.mkdir()
        checked([git, "init", "-q", "-b", "main"], repo, env)
        checked([git, "config", "user.name", "Benchmark Author"], repo, env)
        checked([git, "config", "user.email", "benchmark@example.invalid"], repo, env)
        for i in range(100):
            (repo / f"module_{i:03}.txt").write_text(f"module {i}: enabled=true\n")
        (repo / "config.txt").write_text("".join(f"option_{i:03}=safe\n" for i in range(600)))
        checked([git, "add", "."], repo, env)
        checked([git, "commit", "-qm", "revision_000: initialize configuration"], repo, env)
        for i in range(1, 31):
            checked([git, "commit", "--allow-empty", "-qm",
                     f"revision_{i:03}: configure service {i}"], repo, env)
        for i in range(changed):
            (repo / f"module_{i:03}.txt").write_text(f"module {i}: enabled=false\n")
        if name == "git-small":
            text = (repo / "config.txt").read_text().replace("option_300=safe", "option_300=unsafe")
        else:
            text = "".join(f"option_{i:03}={'unsafe' if i == 300 else 'changed'}\n" for i in range(600))
        (repo / "config.txt").write_text(text)
    logs = work / "logs"
    logs.mkdir()
    (logs / "repeated.log").write_text(
        "INFO service booted\n" + "INFO heartbeat healthy\n" * 1600
        + "ERROR payment failed: upstream timeout request_id=REQ-421\n"
        + "INFO heartbeat healthy\n" * 1600 + "INFO shutdown completed\n")
    (logs / "timestamped.log").write_text("".join(
        "2026-10-09T10:25:00Z ERROR upstream timeout request_id=REQ-422\n" if i == 1500
        else f"2026-10-09T10:{i//60:02}:{i%60:02}Z INFO heartbeat sequence={i:04}\n"
        for i in range(3000)))
    (logs / "small.log").write_text("INFO booted\nERROR request_id=REQ-423 failed\nINFO stopped\n")
    (logs / "long-lines.log").write_text("".join(f"line={i:02} " + "payload=abcdefgh " * 900 + "\n" for i in range(10)))
    (work / "medium.txt").write_text("".join(
        f"setting_{i:03}={'critical_timeout=417' if i == 250 else 'enabled'}\n" for i in range(500)))
    (work / "response.json").write_text(json.dumps({"records": [
        {"id": i, "status": "failed" if i == 250 else "ready", "message": f"record-{i:03}"}
        for i in range(500)], "total": 500}, indent=2))
    for name, count in [("list-small", 6), ("list-many", 100)]:
        d = work / name
        d.mkdir()
        for i in range(count):
            (d / f"file_{i:03}.txt").write_text("hello\n")
        (d / "nested").mkdir()
        (d / "nested" / "child.txt").write_text("hello\n")
    tests = work / "pytest"
    tests.mkdir()
    (tests / "test_pass.py").write_text("".join(
        f"def test_item_{i:03}():\n    assert {i} + 1 == {i+1}\n\n" for i in range(100)))
    (tests / "test_fail.py").write_text("".join(
        f"def test_failure_{i:03}():\n    actual = {i}\n    expected = {i+1}\n    assert actual == expected\n\n"
        for i in range(12)))
    # Explicit replay executables, never presented as live Docker/Kubernetes/GH.
    replay = work / "replay-bin"
    replay.mkdir()
    for tool in ["docker", "kubectl", "gh", "npm", "cargo"]:
        p = replay / tool
        p.write_text(f"#!{sys.executable}\nimport os,sys,time\n"
                     "if os.environ.get('BENCH_STREAM'):\n"
                     " print('first diagnostic',flush=True)\n"
                     " time.sleep(0.3)\n"
                     " print('middle diagnostic',flush=True)\n"
                     " time.sleep(0.3)\n"
                     " print('last diagnostic',flush=True)\n"
                     "elif os.environ.get('BENCH_INTERLEAVE'):\n"
                     " os.write(1,b'01 stdout\\n');time.sleep(0.03)\n"
                     " os.write(2,b'02 stderr\\n');time.sleep(0.03)\n"
                     " os.write(1,b'03 stdout\\n')\n"
                     "else:\n"
                     " sys.stdout.buffer.write(open(os.environ['BENCH_REPLAY_FILE'],'rb').read())\n"
                     " sys.exit(int(os.environ.get('BENCH_REPLAY_EXIT','0')))\n")
        p.chmod(0o755)
    (logs / "progress.log").write_text("Starting install\n" + "".join(
        f"[{'=' * 12}>    ] {i%100}%\n" for i in range(800))
        + "WARNING deprecated dependency legacy-lib\nInstalled 81 packages\n")
    (logs / "issues.log").write_text("".join(
        f"{i}\tOPEN\tissue_{i:03}: {'timeout regression' if i == 75 else 'update service settings'}\tbug\t2026-10-09T10:00:00Z\n"
        for i in range(150)))


def cases(work, pi, env):
    data = []

    def add(name, group, native, wrapped, facts, *, cwd=work, focused=None, replay=False, extra=None):
        data.append(dict(name=name, group=group, native=native, pi=wrapped,
                         focused=focused, facts=facts, cwd=str(cwd), replay=replay, extra=extra or {}))

    small, many = work / "git-small", work / "git-many"
    for label, cwd in [("small", small), ("many", many)]:
        add(f"git_status_{label}", "git", ["git", "status"], [pi, "git", "status"],
            ["config.txt", "module_004.txt" if label == "small" else "module_050.txt"],
            cwd=cwd, focused=["git", "status", "--short"])
    add("git_log_recent", "git", ["git", "log"], [pi, "git", "log"],
        ["revision_030", "revision_011"], cwd=small, focused=["git", "log", "--oneline", "-n", "20"])
    add("git_log_history", "git", ["git", "log"], [pi, "git", "log"],
        ["revision_005", "Benchmark Author"], cwd=small,
        focused=["git", "log", "--format=%an %s", "--grep=revision_005"])
    add("git_log_explicit", "git", ["git", "log", "--oneline", "-n", "20"],
        [pi, "git", "log", "--oneline", "-n", "20"], ["revision_030"], cwd=small)
    for label, cwd in [("small", small), ("many", many)]:
        add(f"git_diff_{label}", "git", ["git", "diff"], [pi, "git", "diff"],
            ["+option_300=unsafe"], cwd=cwd,
            focused=["git", "diff", "--", "config.txt"] if label == "small" else None)
    add("git_numstat", "git", ["git", "diff", "--numstat"], [pi, "git", "diff", "--numstat"],
        ["config.txt", "module_050.txt"], cwd=many)
    add("git_show_content", "git", ["git", "show", "HEAD:config.txt"],
        [pi, "git", "show", "HEAD:config.txt"], ["option_300=safe"], cwd=small)
    add("git_global_option", "git", ["git", "-C", str(small), "status"],
        [pi, "git", "-C", str(small), "status"], ["module_004.txt"])
    for label in ["small", "many"]:
        path = f"list-{label}"
        add(f"ls_{label}", "files", ["ls", path], [pi, "ls", path], ["file_003.txt", "nested"])
    for label, path, fact in [("small", "source/cargo.rs", "DEFAULT_HEAD_LINES"),
                               ("medium", "medium.txt", "critical_timeout=417"),
                               ("large", "source/summary.rs", "fn normalize_spans")]:
        add(f"read_{label}", "files", ["cat", path], [pi, "read", path], [fact],
            focused=["rg", "-n", "-F", fact, path])
    for mode in ["summary", "signature"]:
        argv = [pi, "summary", "source/summary.rs"] if mode == "summary" else [pi, "read", "source/summary.rs", "--level", "signature"]
        add(mode, "files", ["cat", "source/summary.rs"], argv,
            ["fn summarize_code", "fn normalize_spans", "fn build_segments"],
            focused=["rg", "-n", "^(pub )?fn ", "source/summary.rs"])
    for label, pat, flags in [("narrow", "fn normalize_spans", []),
                              ("context", "fn normalize_spans", ["-B", "1", "-A", "3"]),
                              ("broad", "fn ", [])]:
        add(f"grep_{label}", "files", ["rg", "-n", *flags, pat, "source/summary.rs"],
            [pi, "grep", "--pattern", pat, "--path", "source/summary.rs"],
            ["fn normalize_spans"])
    for label, fact in [("repeated", "request_id=REQ-421"), ("timestamped", "request_id=REQ-422"),
                         ("small", "request_id=REQ-423"), ("long-lines", "line=05")]:
        path = f"logs/{label}.log"
        add(f"log_{label}", "logs", ["cat", path], [pi, "log", path], [fact],
            focused=["rg", "-n", "-F", "ERROR" if label != "long-lines" else "line=05", path])
    add("json_values", "files", ["jq", ".", "response.json"], [pi, "json", "response.json"],
        ["record-250", '"total": 500'], focused=["jq", '{total, failed: [.records[] | select(.status == "failed")]}', "response.json"])
    add("json_structure", "files", ["jq", ".", "response.json"], [pi, "json", "response.json", "--structure"],
        ["records", "status", "message"], focused=["jq", "{total, records: {keys: (.records[0] | keys)}}", "response.json"])
    test_env = {"PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"}
    for label in ["pass", "fail"]:
        path = f"test_{label}.py"
        facts = ["100 passed"] if label == "pass" else ["test_failure_006", "assert 6 == 7", "12 failed"]
        add(f"pytest_{label}", "tests", ["pytest", path, "--color=no"],
            [pi, "pytest", path, "--color=no"], facts, cwd=work / "pytest",
            focused=["pytest", "-q", path, "--color=no"], extra=test_env)
    source = ROOT / "home/cli/pi-rs"
    add("cargo_workspace", "tests", ["cargo", "test", "--workspace", "--offline"],
        [pi, "cargo", "test", "--workspace", "--offline"], ["test result: ok."], cwd=source,
        focused=["cargo", "test", "--workspace", "--offline", "--quiet"],
        extra={"CARGO_TERM_COLOR": "never"})
    replay_env = {"PATH": str(work / "replay-bin") + os.pathsep + env["PATH"]}
    for tool, args, filename, fact in [
        ("docker", ["logs", "fixture"], "repeated.log", "request_id=REQ-421"),
        ("kubectl", ["logs", "fixture"], "timestamped.log", "request_id=REQ-422"),
        ("npm", ["install"], "progress.log", "legacy-lib"),
        ("gh", ["issue", "list"], "issues.log", "issue_075"),
    ]:
        add(f"replay_{tool}", "replays", [tool, *args], [pi, tool, *args], [fact], replay=True,
            extra={**replay_env, "BENCH_REPLAY_FILE": str(work / "logs" / filename)})
    add("replay_kubectl_json", "replays", ["kubectl", "get", "pods", "-o", "json"],
        [pi, "kubectl", "get", "pods", "-o", "json"], ["record-250"], replay=True,
        extra={**replay_env, "BENCH_REPLAY_FILE": str(work / "response.json")})
    return data


def compile_truncator(source_dir, work, env):
    """Compile the unmodified official Rust helper, not our approximation."""
    source = source_dir / "codex-rs_utils_string_src_truncate.rs"
    driver = work / "truncate-driver.rs"
    driver.write_text(f'#[path = {json.dumps(str(source))}] mod truncate;\n'
                      'use std::io::{self, Read};\n'
                      'fn main() { let mut s=String::new(); io::stdin().read_to_string(&mut s).unwrap();\n'
                      'let n:usize=std::env::args().nth(1).unwrap().parse().unwrap();\n'
                      'if s.len()>n*4 { println!("Warning: truncated output (original token count: {})\\nTotal output lines: {}\\n",'
                      ' (s.len()+3)/4,s.lines().count()); }\n'
                      'print!("{}",truncate::truncate_middle_with_token_budget(&s,n).0); }\n')
    binary = work / "truncate-driver"
    checked(["rustc", "--edition=2024", "-O", "-Awarnings", str(driver), "-o", str(binary)], work, env)
    return binary


def capped(text, limit, truncator):
    return subprocess.run([str(truncator), str(limit)], input=text, text=True,
                          capture_output=True, check=True).stdout


def visible(text, code, limit, truncator):
    # Hold common metadata constant. Include per-call framing for recovery costs.
    header = f"Chunk ID: abc123\nWall time: 0.0100 seconds\nProcess exited with code {code}\nOutput:\n"
    return header + capped(text, limit, truncator)


def interval(values):
    rng = random.Random(937)
    samples = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(2000))
    return [samples[49], samples[1949]]


def analyze_case(case, work, pi, env, truncator, repeats, evidence, rng):
    cwd = Path(case["cwd"])
    run_env = {**env, **case["extra"]}
    variants = [v for v in ["native", "pi", "focused"] if case[v]]
    measurements = {v: [] for v in variants}
    first = {}
    tee_dir = work / "data/pi-rs/tee"
    tee_before = set(tee_dir.glob("*"))
    # One unmeasured warm-up per variant; then alternate random orders.
    for v in variants:
        output, code, _ = run(case[v], cwd, run_env)
        first[v] = (output, code)
    for _ in range(repeats):
        order = variants.copy()
        rng.shuffle(order)
        for v in order:
            output, code, elapsed = run(case[v], cwd, run_env)
            measurements[v].append(elapsed)
            if code != first[v][1]:
                raise RuntimeError(f"Unstable exit status: {case['name']} {v}")
    result = {**case, "variants": {}, "latency_pi_minus_native_ms": None}
    tee_new = set(tee_dir.glob("*")) - tee_before
    result["tee_storage"] = dict(files=len(tee_new), bytes=sum(p.stat().st_size for p in tee_new),
                                 invocations_per_variant=repeats + 1)
    for v, (output, code) in first.items():
        raw_file = evidence / f"{case['name']}.{v}.txt"
        raw_file.write_text(output)
        counts = {}
        for limit in [1000, 4000, 10000]:
            shown = visible(output, code, limit, truncator)
            counts[str(limit)] = dict(tokens=tokens(shown),
                                     retained=[f in shown for f in case["facts"]],
                                     bytes=len(shown.encode()))
        result["variants"][v] = dict(exit_code=code, bytes=len(output.encode()), raw_tokens=tokens(output),
            sha256=sha(output.encode()), visible=counts, timing_ms=measurements[v],
            median_ms=statistics.median(measurements[v]))
    diffs = [b-a for a, b in zip(measurements["native"], measurements["pi"])]
    result["latency_pi_minus_native_ms"] = dict(median=statistics.median(diffs),
                                               bootstrap_95_ci=interval(diffs))
    # A recovery query deliberately knows the task target, equally for both sides.
    # It measures an attainable lower bound, not an LLM's probability of choosing it.
    recovered = {}
    for v in ["native", "pi"]:
        output, code = first[v]
        missing = [f for f, kept in zip(case["facts"], result["variants"][v]["visible"]["10000"]["retained"]) if not kept]
        recovery = dict(needed=bool(missing), calls=0, tokens={n: 0 for n in ENCODERS}, retained_after=None)
        if missing:
            match = re.search(r"full output: ([^\]\n]+)", output) if v == "pi" else None
            if match:
                recovery_path = Path(match.group(1))
                recovery["tee_bytes"] = recovery_path.stat().st_size
                recovery["tee_sha256"] = sha(recovery_path.read_bytes())
                full = checked([pi, "read", "--no-truncate", str(recovery_path)], cwd, run_env)
                recovery["full_read_visible_tokens"] = tokens(visible(full, 0, 10000, truncator))
                recovery["full_read_retained"] = [f in capped(full, 10000, truncator) for f in missing]
                recovery["full_read_matches_file"] = full.encode() == recovery_path.read_bytes()
                command = ["rg", "-n", "-F", *sum((["-e", f] for f in missing), []), str(recovery_path)]
            elif v == "native":
                # Stable fixture output saved externally; assume native redirection
                # was planned. Also report this optimistic baseline explicitly.
                command = ["rg", "-n", "-F", *sum((["-e", f] for f in missing), []), str(evidence / f"{case['name']}.native.txt")]
            else:
                command = None  # Semantic omission (e.g. Git default -n20), no tee.
            if command:
                extra, recovery_code, latency = run(command, cwd, run_env)
                recovery.update(calls=1, tokens=tokens(visible(extra, recovery_code, 10000, truncator)),
                                command_tokens=tokens(shlex.join(command)), command=command, latency_ms=latency,
                                retained_after=[f in capped(output, 10000, truncator) or f in capped(extra, 10000, truncator) for f in case["facts"]])
                (evidence / f"{case['name']}.{v}.recovery.txt").write_text(extra)
            else:
                recovery["retained_after"] = [f in capped(output, 10000, truncator) for f in case["facts"]]
                recovery["unrecoverable_from_initial_payload"] = True
        else:
            recovery["retained_after"] = result["variants"][v]["visible"]["10000"]["retained"]
        recovered[v] = recovery
    result["recovery"] = recovered
    for v in variants:
        argv = ["pi-rs" if arg == pi else arg for arg in case[v]]
        result["variants"][v]["command_tokens"] = tokens(shlex.join(argv))
    return result


def streaming(work, pi, env, repeats=7):
    data = {}
    replay_env = {**env, "PATH": str(work / "replay-bin") + os.pathsep + env["PATH"], "BENCH_STREAM": "1"}
    for v, cmd in [("native", [str(work / "replay-bin/cargo"), "test"]), ("pi", [pi, "cargo", "test"])]:
        rows = []
        for _ in range(repeats):
            start = time.perf_counter()
            p = subprocess.Popen(cmd, env=replay_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            first = p.stdout.read(1)
            first_ms = (time.perf_counter() - start) * 1000
            output = first + p.stdout.read()
            p.wait(timeout=5)
            rows.append(dict(first_byte_ms=first_ms, total_ms=(time.perf_counter()-start)*1000,
                             output=output.decode(), exit_code=p.returncode))
        data[v] = rows
    sequence_env = {**env, "PATH": replay_env["PATH"], "BENCH_INTERLEAVE": "1"}
    for v, cmd in [("native", [str(work / "replay-bin/cargo"), "test"]), ("pi", [pi, "cargo", "test"])]:
        data[v + "_interleaved"] = subprocess.run(cmd, env=sequence_env, capture_output=False,
             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True).stdout
    return data


def finish_recovery(result, env, truncator, evidence):
    """Measure a second native invocation where pi-rs produced no recovery file."""
    for case in result["cases"]:
        recovery = case["recovery"]["pi"]
        if not recovery.get("unrecoverable_from_initial_payload"):
            continue
        facts = case["facts"]
        initial = (evidence / f"{case['name']}.pi.txt").read_text()
        missing = [f for f in facts if f not in capped(initial, 10000, truncator)]
        argv = case["focused"] or case["native"]
        raw, code, elapsed = run(argv, case["cwd"], {**env, **case["extra"]})
        query = ["rg", "-n", "-F", *sum((["-e", f] for f in missing), [])]
        start = time.perf_counter_ns()
        filtered = subprocess.run(query, input=raw, text=True, capture_output=True, check=False)
        elapsed += (time.perf_counter_ns() - start) / 1e6
        command = shlex.join(argv) + " | " + shlex.join(query)
        shown = visible(filtered.stdout, filtered.returncode, 10000, truncator)
        recovery.update(calls=1, tokens=tokens(shown), command_tokens=tokens(command),
                        command=command, latency_ms=elapsed, rerun_exit_code=code,
                        strategy="rerun native command and filter in one shell call",
                        retained_after=[f in capped(initial, 10000, truncator) or f in shown for f in facts])
        (evidence / f"{case['name']}.pi.recovery.txt").write_text(filtered.stdout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=Path, required=True, help="New directory under /tmp")
    parser.add_argument("--codex-source-dir", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=21)
    parser.add_argument("--pi", default=shutil.which("pi-rs"))
    args = parser.parse_args()
    if args.repeats < 3:
        parser.error("Use at least three timing pairs")
    env = {**os.environ, "LC_ALL": "C", "LANG": "C", "NO_COLOR": "1", "TERM": "dumb",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_PAGER": "cat",
           "GIT_AUTHOR_DATE": "2026-10-09T10:00:00Z", "GIT_COMMITTER_DATE": "2026-10-09T10:00:00Z",
           "XDG_DATA_HOME": str(args.work / "data"),
           "PATH": str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"]}
    pi = str(Path(args.pi).resolve())
    prepare(args.work, env)
    truncator = compile_truncator(args.codex_source_dir.resolve(), args.work, env)
    evidence = args.work / "evidence"
    evidence.mkdir()
    manifest = cases(args.work, pi, env)
    (args.work / "manifest.json").write_text(json.dumps(manifest, indent=2))
    metadata = dict(host=platform.node(), platform=platform.platform(), python=sys.version,
                    tiktoken=tiktoken.__version__, pi=pi, pi_sha256=sha(Path(pi).read_bytes()),
                    pi_version=checked([pi, "--version"], args.work, env).strip(),
                    codex_commit=CODEX_COMMIT, repeats=args.repeats, seed=4281,
                    snapshot_sha256=sha((HERE / "source-snapshot.tar.gz").read_bytes()),
                    instructions_tokens=tokens((args.work / "source/codex-rules.md").read_text()),
                    source_hashes={f: sha((args.codex_source_dir / f.replace("/", "_")).read_bytes()) for f in SOURCE_FILES})
    result = dict(metadata=metadata, cases=[])
    rng = random.Random(4281)
    for case in manifest:
        print(f"Running {case['name']}", flush=True)
        result["cases"].append(analyze_case(case, args.work, pi, env, truncator, args.repeats, evidence, rng))
        (args.work / "results.partial.json").write_text(json.dumps(result, indent=2))
    finish_recovery(result, env, truncator, evidence)
    result["streaming_replay"] = streaming(args.work, pi, env)
    (args.work / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Complete: {len(manifest)} cases; {args.work / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
