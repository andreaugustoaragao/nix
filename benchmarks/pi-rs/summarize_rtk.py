#!/usr/bin/env python3
"""Validate the fresh three-arm evidence and write tables and a plot."""
import argparse
import json
from pathlib import Path
import statistics

import benchmark as b
from compare_rtk import ARMS, retained


def count(case, arm, budget=10000, encoder="o200k_base"):
    return case["variants"][arm]["visible"][str(budget)]["tokens"][encoder]


def aggregate(cases, budget=10000, encoder="o200k_base"):
    result = dict(cases=len(cases), facts=sum(len(c["facts"]) for c in cases))
    for arm in ARMS:
        result[arm] = dict(initial_tokens=sum(count(c, arm, budget, encoder) for c in cases),
            retained=sum(sum(c["variants"][arm]["visible"][str(budget)]["retained"]) for c in cases))
        if budget == 10000:
            result[arm].update(recovery_calls=sum(c["recovery"][arm]["calls"] for c in cases),
                retained_after_recovery=sum(sum(c["recovery"][arm]["retained_after"]) for c in cases))
            result[arm]["response_command_recovery_tokens"] = sum(count(c, arm, budget, encoder)
                + c["variants"][arm]["command_tokens"][encoder]
                + c["recovery"][arm]["tokens"][encoder]
                + c["recovery"][arm]["command_tokens"][encoder] for c in cases)
    for arm in ("pi", "rtk"):
        result[arm]["initial_saving_percent"] = 100 * (1-result[arm]["initial_tokens"]/result["native"]["initial_tokens"])
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("work", type=Path)
    parser.add_argument("--no-plot", action="store_true")
    args = parser.parse_args()
    data = json.loads((args.work / "results.json").read_text())
    cases = data["cases"]
    evidence = args.work / "evidence"
    truncator = args.work / "truncate-driver"
    mismatches = []
    outputs = 0
    for case in cases:
        for arm, v in case["variants"].items():
            raw = (evidence / f"{case['name']}.{arm}.txt").read_bytes()
            assert b.sha(raw) == v["sha256"]
            assert len(v["timing_ms"]) == data["metadata"]["repeats"]
            for budget in (1000, 4000, 10000):
                shown = b.visible(raw.decode(), v["exit_code"], budget, truncator)
                assert b.tokens(shown) == v["visible"][str(budget)]["tokens"]
                assert retained(case["facts"], shown) == v["visible"][str(budget)]["retained"]
            outputs += 1
        native_exit = case["variants"]["native"]["exit_code"]
        assert native_exit == (1 if case["name"] == "pytest_fail" else 0)
        for arm in ARMS:
            if case["variants"][arm]["exit_code"] != native_exit:
                mismatches.append(dict(case=case["name"], arm=arm, native_exit=native_exit,
                                       exit_code=case["variants"][arm]["exit_code"]))
            rec = case["recovery"][arm]
            kept = case["variants"][arm]["visible"]["10000"]["retained"]
            for i, step in enumerate(rec["steps"], 1):
                raw = (evidence / f"{case['name']}.{arm}.recovery-{i}.txt").read_bytes()
                assert b.sha(raw) == step["sha256"]
                shown = b.visible(raw.decode(), step["exit_code"], 10000, truncator)
                assert b.tokens(shown) == step["tokens"]
                assert b.tokens(step["command"]) == step["command_tokens"]
                kept = [a or z for a, z in zip(kept, retained(case["facts"], shown))]
            assert kept == rec["retained_after"]
            for key in ("tokens", "command_tokens"):
                assert rec[key] == {e: sum(s[key][e] for s in rec["steps"]) for e in b.ENCODERS}
    primary = [c for c in cases if not c["replay"]]
    for row in data.get("rtk_recall_audit", []):
        raw = (evidence / f"recall-{row['hash']}.txt").read_bytes()
        assert b.sha(raw) == row["sha256"]
        assert row["exit_code"] == 0 and row["byte_equal_to_store"]
    result = dict(primary=aggregate(primary), all=aggregate(cases),
        groups={g: aggregate([c for c in cases if c["group"] == g]) for g in ("git", "files", "logs", "tests", "replays")},
        budgets={str(n): aggregate(primary, n) for n in (1000, 4000, 10000)},
        encoders={e: aggregate(primary, encoder=e) for e in b.ENCODERS},
        median_case_overhead_ms={a: statistics.median(c["latency_vs_native_ms"][a]["median"] for c in primary) for a in ("pi", "rtk")},
        storage=dict(pi_tee_files=sum(sum(k.endswith((".log", ".log.gz")) for k in c["pi_tee_created"]) for c in cases),
            pi_tee_bytes=sum(sum(c["pi_tee_created"].values()) for c in cases),
            rtk_files={k:v for k,v in data["storage_final"].items() if k.startswith("rtk-state/")},
            rtk_recall_entries=len(data.get("rtk_recall_entries", [])),
            rtk_recalled_raw_bytes=sum(r["byte_size"] for r in data.get("rtk_recall_entries", [])),
            rtk_compressed_blob_bytes=sum(r["compressed_bytes"] for r in data.get("rtk_recall_entries", []))),
        streaming={a: {m: statistics.median(r[m] for r in data["streaming_replay"][a])
                      if all(r[m] is not None for r in data["streaming_replay"][a]) else None
                      for m in ("first_byte_ms", "total_ms")} for a in ARMS},
        validation=dict(initial_outputs_verified=outputs, exit_mismatches=mismatches,
            rtk_recall_payloads_verified=len(data.get("rtk_recall_audit", [])),
            incomplete_recovery=[dict(case=c["name"], arm=a) for c in cases for a in ARMS if not all(c["recovery"][a]["retained_after"])]))
    if "streaming_cargo_shaped_replay" in data:
        result["streaming_cargo_shaped"] = {a: {m: statistics.median(r[m] for r in data["streaming_cargo_shaped_replay"][a])
            if all(r[m] is not None for r in data["streaming_cargo_shaped_replay"][a]) else None
            for m in ("first_byte_ms", "total_ms")} for a in ARMS}
    focused = [c for c in primary if c["focused"]]
    result["focused"] = dict(cases=len(focused), facts=sum(len(c["facts"]) for c in focused),
        variants={a: dict(tokens=sum(count(c,a) for c in focused),
                          retained=sum(sum(c["variants"][a]["visible"]["10000"]["retained"]) for c in focused)) for a in ("focused", "pi", "rtk")})
    (args.work / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    lines = ["# Native / pi-rs / RTK: command details", "",
        f"Fresh measurements on identical regenerated fixtures. N = native, P = {data['metadata']['binaries']['pi']['version']}, R = {data['metadata']['binaries']['rtk']['version']}.", "",
        "Tokens use o200k_base after the same Codex 10,000 approximate-token cap, with fixed execution headers.", "",
        "| Case | N tokens | P tokens | R tokens | Facts N / P / R / total | Exit N / P / R |",
        "|---|---:|---:|---:|---|---|"]
    for c in cases:
        facts = " / ".join(str(sum(c["variants"][a]["visible"]["10000"]["retained"])) for a in ARMS)
        exits = " / ".join(str(c["variants"][a]["exit_code"]) for a in ARMS)
        lines.append(f"| {c['name']} | {count(c,'native'):,} | {count(c,'pi'):,} | {count(c,'rtk'):,} | {facts} / {len(c['facts'])} | {exits} |")
    lines += ["", "The final five cases are synthetic subprocess replays, excluded from the primary aggregate.", "",
        "## Recovery", "", "Targeted recovery knows each task's facts. Native assumes a previously saved output.",
        "Full rereads are separate diagnostics; their token cost is excluded from the targeted sequence.", "",
        "| Case | Arm | Extra calls | Response tokens | Facts after / total | Strategies |", "|---|---|---:|---:|---|---|"]
    for c in cases:
        for a in ARMS:
            r = c["recovery"][a]
            if r["needed"]:
                strategy = "; ".join(s["strategy"] for s in r["steps"])
                lines.append(f"| {c['name']} | {a} | {r['calls']} | {r['tokens']['o200k_base']:,} | {sum(r['retained_after'])} / {len(c['facts'])} | {strategy} |")
    lines += ["", "## Warm command overhead", "", f"Paired median differences and 95% bootstrap intervals in milliseconds; {data['metadata']['repeats']} repetitions per case.", "",
              "| Case | pi-rs minus native | RTK minus native |", "|---|---:|---:|"]
    for c in cases:
        columns = []
        for a in ("pi", "rtk"):
            d = c["latency_vs_native_ms"][a]
            lo, hi = d["bootstrap_95_ci"]
            columns.append(f"{d['median']:+.2f} [{lo:+.2f}, {hi:+.2f}]")
        lines.append(f"| {c['name']} | {' | '.join(columns)} |")
    lines += ["", "## Scope and mappings", "",
        "- RTK summary/signature intent maps to `rtk read --level aggressive`; `rtk summary` runs a command.",
        "- RTK grep gets the native rg arguments, including explicit context flags.",
        "- RTK JSON structure intent maps to `rtk json --keys-only`.",
        "- Equivalent unquoted `total: 500` and `cargo test: N passed` count as the corresponding facts for every arm.",
        "- Direct-command RTK measurements suppress its missing-hook installation warning, disable telemetry, and retain default tracking and SQLite recovery.",
        "- Direct timings exclude hook invocation and model decisions. The separate Codex matrix includes the installed integration.",
        "- Command totals exclude instruction documents; provider input usage in the model experiment includes integration overhead."]
    (args.work / "command-details.md").write_text("\n".join(lines) + "\n")
    print(json.dumps(result, indent=2))
    if args.no_plot:
        return
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5), layout="constrained")
    groups = ("git", "files", "logs", "tests")
    colors = ("#52677D", "#127B76", "#C27D1C")
    for i, (a, label) in enumerate(zip(ARMS, ("Native", "pi-rs", "RTK"))):
        y = [j+(i-1)*.24 for j in range(4)]
        values = [result["groups"][g][a]["initial_tokens"]/1000 for g in groups]
        axes[0].barh(y, values, .22, label=label, color=colors[i])
        for x, yy in zip(values, y):
            axes[0].text(x+.4, yy, f"{x:.1f}", va="center", fontsize=8)
        values = [100*result["groups"][g][a]["retained"]/result["groups"][g]["facts"] for g in groups]
        axes[1].barh(y, values, .22, color=colors[i])
        for x, yy, g in zip(values, y, groups):
            axes[1].text(x+1, yy, f"{result['groups'][g][a]['retained']}/{result['groups'][g]['facts']}", va="center", fontsize=8)
    for ax in axes:
        ax.set_yticks(range(4), ("Git (10)", "Files/search (12)", "Logs (4)", "Tests (3)"))
        ax.invert_yaxis()
        ax.spines[["top", "right"]].set_visible(False)
        ax.grid(axis="x", alpha=.15)
        ax.set_axisbelow(True)
    axes[0].legend(frameon=False)
    axes[0].set_xlabel("Initial visible output, thousands of BPE tokens")
    axes[1].set_xlabel("Requested facts initially present (%)")
    axes[1].set_xlim(0, 120)
    axes[1].set_xticks((0, 25, 50, 75, 100))
    fig.suptitle("Command compression and evidence retention: native / pi-rs / RTK")
    fig.savefig(args.work / "command-comparison.png", dpi=170)


if __name__ == "__main__":
    main()
