#!/usr/bin/env python3
"""Fresh native/pi-rs/RTK command matrix, reusing the frozen two-arm fixtures.

All execution uses argv, bypassing shell hooks. See README.md for limitations.
"""
import argparse
from contextlib import closing
import gzip
import json
import os
from pathlib import Path
import platform
import random
import re
import shlex
import shutil
import sqlite3
import statistics
import subprocess
import sys
import time

import benchmark as b

ARMS = ("native", "pi", "rtk")


def retained(facts, output):
    """Accept equivalent formatting, consistently for every variant."""
    def present(fact):
        if fact in output:
            return True
        if fact == '"total": 500':
            return bool(re.search(r'(?m)^\s*total:\s*500\s*$', output))
        if fact == "test result: ok.":
            return bool(re.search(r'cargo test: [1-9]\d* passed(?: \(|,|$)', output))
        return False
    return [present(f) for f in facts]


def rtk_command(case, rtk):
    name, native = case["name"], case["native"]
    if name in ("summary", "signature"):
        return [rtk, "read", "source/summary.rs", "--level", "aggressive"]
    if name.startswith("read_"):
        return [rtk, "read", *native[1:]]
    if name.startswith("grep_"):
        return [rtk, "grep", *native[1:]]
    if name.startswith("log_"):
        return [rtk, "log", *native[1:]]
    if name.startswith("json_"):
        return [rtk, "json", "response.json"] + (["--keys-only"] if name == "json_structure" else [])
    return [rtk, *native]


def storage(work):
    paths = list((work / "data").rglob("*")) + list((work / "rtk-state").rglob("*"))
    return {str(p.relative_to(work)): p.stat().st_size for p in paths if p.is_file()}


def named(argv, pi, rtk):
    return ["pi-rs" if x == pi else "rtk" if x == rtk else x for x in argv]


def recover(case, arm, raw, work, env, truncator, evidence, pi, rtk):
    """Measure targeted recovery. Oracle targets are identical across arms.

    Full rereads are separate diagnostics, not counted in the targeted sequence.
    If a stored payload cannot restore all targets, count a native rerun too.
    """
    initial = b.capped(raw, 10000, truncator)
    kept = retained(case["facts"], initial)
    result = dict(needed=not all(kept), calls=0, tokens={n: 0 for n in b.ENCODERS},
                  command_tokens={n: 0 for n in b.ENCODERS}, steps=[], retained_after=kept)
    if all(kept):
        return result
    missing = [f for f, ok in zip(case["facts"], kept) if not ok]
    run_env = {**env, **case["extra"]}
    tee = re.search(r"full output: ([^\]\n]+)", raw) if arm == "pi" else None
    hashes = re.findall(r"rtk recall ([0-9a-f]+)", raw) if arm == "rtk" else []
    query = ["rg", "-n", "-F", *sum((["-e", f] for f in missing), [])]
    command = None
    if tee:
        path = Path(tee.group(1))
        full, code, _ = b.run([pi, "read", "--no-truncate", str(path)], case["cwd"], run_env)
        result.update(storage_path=str(path), storage_sha256=b.sha(path.read_bytes()),
                      full_read_matches_file=full.encode() == (gzip.decompress(path.read_bytes()) if path.suffix == ".gz" else path.read_bytes()))
        command = [pi, "read", str(path), "--grep", "|".join(map(re.escape, missing)), "-n"] if path.suffix == ".gz" else [*query, str(path)]
        strategy = "target pi recovery file"
    elif hashes:
        # Last hint is the outer command's complete output for nested filters.
        full, code, _ = b.run([rtk, "recall", hashes[-1], "--full"], case["cwd"], run_env)
        command = [rtk, "recall", hashes[-1], "--full", "--grep", "|".join(map(re.escape, missing))]
        result.update(recall_hash=hashes[-1])
        strategy = "target RTK recall store"
    elif arm == "native":
        command = [*query, str(evidence / f"{case['name']}.native.txt")]
        strategy = "target pre-saved native output (optimistic)"
    if tee or hashes:
        result["full_read_tokens"] = b.tokens(b.visible(full, code, 10000, truncator))
        result["full_read_retained"] = retained(missing, b.capped(full, 10000, truncator))
        result["full_read_exit_code"] = code
        (evidence / f"{case['name']}.{arm}.full-recovery.txt").write_text(full)

    def record(output, code, command_text, elapsed, strategy):
        shown = b.visible(output, code, 10000, truncator)
        result["calls"] += 1
        step = dict(strategy=strategy, command=command_text, exit_code=code,
                    tokens=b.tokens(shown), command_tokens=b.tokens(command_text),
                    latency_ms=elapsed, sha256=b.sha(output.encode()))
        result["steps"].append(step)
        for key in ("tokens", "command_tokens"):
            for encoder in b.ENCODERS:
                result[key][encoder] += step[key][encoder]
        result["retained_after"] = [a or z for a, z in zip(result["retained_after"], retained(case["facts"], shown))]
        (evidence / f"{case['name']}.{arm}.recovery-{result['calls']}.txt").write_text(output)

    if command:
        output, code, elapsed = b.run(command, case["cwd"], run_env)
        record(output, code, shlex.join(named(command, pi, rtk)), elapsed, strategy)
    if not all(result["retained_after"]):
        missing = [f for f, ok in zip(case["facts"], result["retained_after"]) if not ok]
        argv = case["focused"] or case["native"]
        output, code, elapsed = b.run(argv, case["cwd"], run_env)
        query = ["rg", "-n", "-F", *sum((["-e", f] for f in missing), [])]
        start = time.perf_counter()
        filtered = subprocess.run(query, input=output, text=True, capture_output=True)
        elapsed += (time.perf_counter() - start) * 1000
        record(filtered.stdout, filtered.returncode, shlex.join(argv) + " | " + shlex.join(query),
               elapsed, "rerun native command and filter in one shell call")
        result["steps"][-1]["rerun_exit_code"] = code
    return result


def analyze(case, work, env, truncator, repeats, evidence, rng, pi, rtk):
    variants = list(ARMS) + (["focused"] if case["focused"] else [])
    measurements = {v: [] for v in variants}
    first = {}
    before = storage(work)
    run_env = {**env, **case["extra"]}
    for arm in variants:
        out, code, _ = b.run(case[arm], case["cwd"], run_env)
        first[arm] = out, code
    for _ in range(repeats):
        order = variants.copy()
        rng.shuffle(order)
        for arm in order:
            out, code, elapsed = b.run(case[arm], case["cwd"], run_env)
            if code != first[arm][1]:
                (evidence / f"{case['name']}.{arm}.unstable.txt").write_text(out)
                raise RuntimeError(f"Unstable exit: {case['name']} {arm}: {first[arm][1]} -> {code}; output archived")
            measurements[arm].append(elapsed)
    after = storage(work)
    result = {**case, "variants": {}, "latency_vs_native_ms": {},
              "storage_delta_bytes": sum(after.values()) - sum(before.values()),
              "pi_tee_created": {k: v for k, v in after.items() if k.startswith("data/pi-rs/tee/") and k not in before}}
    for arm, (raw, code) in first.items():
        (evidence / f"{case['name']}.{arm}.txt").write_text(raw)
        counts = {}
        for limit in (1000, 4000, 10000):
            shown = b.visible(raw, code, limit, truncator)
            counts[str(limit)] = dict(tokens=b.tokens(shown), retained=retained(case["facts"], shown), bytes=len(shown.encode()))
        result["variants"][arm] = dict(exit_code=code, bytes=len(raw.encode()), raw_tokens=b.tokens(raw),
            sha256=b.sha(raw.encode()), visible=counts, timing_ms=measurements[arm],
            median_ms=statistics.median(measurements[arm]), command_tokens=b.tokens(shlex.join(named(case[arm], pi, rtk))))
    for arm in ("pi", "rtk"):
        delta = [v-n for n, v in zip(measurements["native"], measurements[arm])]
        result["latency_vs_native_ms"][arm] = dict(median=statistics.median(delta), bootstrap_95_ci=b.interval(delta))
    result["recovery"] = {arm: recover(case, arm, first[arm][0], work, env, truncator, evidence, pi, rtk) for arm in ARMS}
    return result


def streaming(work, env, pi, rtk, repeats=7, replay_bin=None, stream_pi=False):
    replay_bin = replay_bin or work / "replay-bin"
    commands = {"native": [str(replay_bin / "cargo"), "test"], "pi": [pi, "cargo", "test"], "rtk": [rtk, "cargo", "test"]}
    base = {**env, "PATH": str(replay_bin) + os.pathsep + env["PATH"]}
    if stream_pi:
        commands["pi_stream"] = [pi, "--stream", "cargo", "test"]
    data = {arm: [] for arm in commands}
    rng = random.Random(1821)
    for _ in range(repeats):
        order = list(commands)
        rng.shuffle(order)
        for arm in order:
            start = time.perf_counter()
            with subprocess.Popen(commands[arm], env={**base, "BENCH_STREAM": "1"}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as p:
                first = p.stdout.read(1)
                first_ms = (time.perf_counter() - start) * 1000 if first else None
                output = first + p.stdout.read()
                p.wait(timeout=10)
                data[arm].append(dict(first_byte_ms=first_ms, total_ms=(time.perf_counter()-start)*1000,
                                      output=output.decode(), exit_code=p.returncode))
    for arm in commands:
        p = subprocess.run(commands[arm], env={**base, "BENCH_INTERLEAVE": "1"},
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
        data[arm + "_interleaved"] = dict(output=p.stdout, exit_code=p.returncode)
    return data


def cargo_shaped_streaming(work, env, pi, rtk, stream_pi=False):
    directory = work / "replay-cargo-shaped-bin"
    directory.mkdir(exist_ok=True)
    script = directory / "cargo"
    script.write_text(f"#!{sys.executable}\nimport time\n"
        "print('   Compiling fixture v0.1.0 (/tmp/fixture)', flush=True)\n"
        "time.sleep(0.3)\nprint('running 1 test', flush=True)\n"
        "time.sleep(0.3)\nprint('test tests::works ... ok\\n\\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.60s', flush=True)\n")
    script.chmod(0o755)
    return streaming(work, env, pi, rtk, replay_bin=directory, stream_pi=stream_pi)


def audit_recall(work, env, rtk, evidence):
    """Read all advertised initial-output hashes against a private DB copy."""
    directory = work / "recall-audit"
    directory.mkdir(exist_ok=True)
    database = directory / "recall.db"
    with closing(sqlite3.connect(f"file:{work / 'rtk-state/recall.db'}?mode=ro", uri=True)) as source:
        with closing(sqlite3.connect(database)) as target:
            source.backup(target)
    run_env = {**env, "RTK_RECALL_DB": str(database), "RTK_DB_PATH": str(directory / "history.db")}
    hashes = sorted({h for p in evidence.glob("*.rtk.txt") for h in re.findall(r"rtk recall ([0-9a-f]+)", p.read_text())})
    rows = []
    with closing(sqlite3.connect(database)) as db:
        for prefix in hashes:
            stored = db.execute("SELECT codec, blob FROM recall WHERE hash LIKE ?", (prefix + "%",)).fetchall()
            raw, code, elapsed = b.run([rtk, "recall", prefix, "--full"], work, run_env)
            matched = False
            if len(stored) == 1:
                codec, blob = stored[0]
                original = gzip.decompress(blob) if codec == "gzip" else blob
                matched = raw.encode() == original
            (evidence / f"recall-{prefix}.txt").write_text(raw)
            rows.append(dict(hash=prefix, exit_code=code, latency_ms=elapsed,
                             byte_equal_to_store=matched, sha256=b.sha(raw.encode()), bytes=len(raw.encode())))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--codex-source-dir", type=Path, required=True)
    parser.add_argument("--rtk", type=Path, required=True)
    parser.add_argument("--pi", default=shutil.which("pi-rs"))
    parser.add_argument("--repeats", type=int, default=21)
    parser.add_argument("--pi-stream", action="store_true", help="Also measure explicit pi-rs 0.3 live passthrough")
    parser.add_argument("--pi-guidance", type=Path)
    args = parser.parse_args()
    if args.repeats < 3:
        parser.error("At least three timing repetitions are required")
    work, pi, rtk = args.work.resolve(), str(Path(args.pi).resolve()), str(args.rtk.resolve())
    env = {k: v for k, v in os.environ.items() if not k.startswith("RTK_")}
    env.update(LC_ALL="C", LANG="C", NO_COLOR="1", TERM="dumb", GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL="/dev/null", GIT_PAGER="cat", GIT_AUTHOR_DATE="2026-10-09T10:00:00Z",
               GIT_COMMITTER_DATE="2026-10-09T10:00:00Z", XDG_DATA_HOME=str(work / "data"),
               XDG_CONFIG_HOME=str(work / "config"), RTK_DB_PATH=str(work / "rtk-state/history.db"),
               RTK_RECALL_DB=str(work / "rtk-state/recall.db"), RTK_TEE_DIR=str(work / "rtk-state/tee"),
               RTK_TELEMETRY_DISABLED="1", RTK_SUPPRESS_HOOK_WARNING="1",
               PATH=str(Path(sys.executable).parent) + os.pathsep + env["PATH"])
    b.prepare(work, env)
    (work / "rtk-state").mkdir()
    (work / "config").mkdir()
    truncator = b.compile_truncator(args.codex_source_dir.resolve(), work, env)
    evidence = work / "evidence"
    evidence.mkdir()
    manifest = b.cases(work, pi, env)
    for case in manifest:
        case["rtk"] = rtk_command(case, rtk)
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    metadata = dict(host=platform.node(), platform=platform.platform(), python=sys.version,
        tiktoken=b.tiktoken.__version__, repeats=args.repeats, seed=4281, codex_commit=b.CODEX_COMMIT,
        snapshot_sha256=b.sha((b.HERE / "source-snapshot.tar.gz").read_bytes()),
        binaries={arm: dict(path=path, sha256=b.sha(Path(path).read_bytes()),
                            version=b.checked([path, "--version"], work, env).strip()) for arm, path in [("pi", pi), ("rtk", rtk)]},
        instructions_tokens={"pi": b.tokens((args.pi_guidance or (work / "source/codex-rules.md")).read_text())},
        environment_overrides={k: env[k] for k in env if k.startswith(("RTK_", "XDG_", "GIT_"))},
        source_hashes={f: b.sha((args.codex_source_dir / f.replace("/", "_")).read_bytes()) for f in b.SOURCE_FILES},
        semantic_equivalences={'"total": 500': 'a complete line total: 500', "test result: ok.": "cargo test: N passed (N > 0)"})
    result = dict(metadata=metadata, cases=[])
    rng = random.Random(4281)
    for case in manifest:
        print(f"Running {case['name']}", flush=True)
        result["cases"].append(analyze(case, work, env, truncator, args.repeats, evidence, rng, pi, rtk))
        (work / "results.partial.json").write_text(json.dumps(result, indent=2))
    result["streaming_replay"] = streaming(work, env, pi, rtk, stream_pi=args.pi_stream)
    result["streaming_cargo_shaped_replay"] = cargo_shaped_streaming(work, env, pi, rtk, stream_pi=args.pi_stream)
    result["rtk_recall_audit"] = audit_recall(work, env, rtk, evidence)
    result["storage_final"] = storage(work)
    recall = work / "rtk-state/recall.db"
    if recall.exists():
        with sqlite3.connect(recall) as conn:
            result["rtk_recall_entries"] = [dict(zip(["hash", "command", "byte_size", "compressed_bytes", "recalled"], row))
                for row in conn.execute("SELECT hash, command, byte_size, length(blob), recalled FROM recall ORDER BY hash")]
    (work / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Complete: {len(manifest)} cases; {work / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
