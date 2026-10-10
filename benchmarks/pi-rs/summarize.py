#!/usr/bin/env python3
"""Validate evidence, compute report tables, and draw the command comparison."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics


def count(case, variant, budget=10000, encoder="o200k_base"):
    return case["variants"][variant]["visible"][str(budget)]["tokens"][encoder]


def aggregate(cases, rules, budget=10000, encoder="o200k_base"):
    out = {"cases": len(cases), "facts": sum(len(c["facts"]) for c in cases)}
    for variant in ["native", "pi"]:
        out[variant] = {
            "initial_tokens": sum(count(c, variant, budget, encoder) for c in cases),
            "retained": sum(sum(c["variants"][variant]["visible"][str(budget)]["retained"]) for c in cases),
            "recovery_calls": sum(c["recovery"][variant]["calls"] for c in cases),
            "retained_after_recovery": sum(sum(c["recovery"][variant]["retained_after"]) for c in cases),
        }
        if budget == 10000:
            out[variant]["episode_tokens"] = sum(
                count(c, variant, budget, encoder)
                + c["variants"][variant]["command_tokens"][encoder]
                + c["recovery"][variant]["tokens"][encoder]
                + c["recovery"][variant].get("command_tokens", {}).get(encoder, 0)
                for c in cases
            ) + (rules[encoder] if variant == "pi" else 0)
    out["initial_savings_percent"] = 100 * (1 - out["pi"]["initial_tokens"] / out["native"]["initial_tokens"])
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("work", type=Path)
    args = parser.parse_args()
    data = json.loads((args.work / "results.json").read_text())
    cases = data["cases"]
    evidence = args.work / "evidence"
    # Validate every stored output against the measurement, including failures.
    for c in cases:
        for name, variant in c["variants"].items():
            raw = (evidence / f"{c['name']}.{name}.txt").read_bytes()
            assert hashlib.sha256(raw).hexdigest() == variant["sha256"]
            assert len(variant["timing_ms"]) == data["metadata"]["repeats"]
        assert c["variants"]["native"]["exit_code"] == c["variants"]["pi"]["exit_code"]
        for v in ["native", "pi"]:
            assert all(c["recovery"][v]["retained_after"]), (c["name"], v)
        assert c["variants"]["native"]["exit_code"] == (1 if c["name"] == "pytest_fail" else 0)
    rules = data["metadata"]["instructions_tokens"]
    primary = [c for c in cases if not c["replay"]]
    result = {"all": aggregate(cases, rules), "primary": aggregate(primary, rules),
              "groups": {}, "budgets": {}, "encoders": {}}
    for group in ["git", "files", "logs", "tests", "replays"]:
        result["groups"][group] = aggregate([c for c in cases if c["group"] == group], rules)
    for budget in [1000, 4000, 10000]:
        result["budgets"][budget] = aggregate(primary, rules, budget)
    for encoder in ["o200k_base", "cl100k_base"]:
        result["encoders"][encoder] = aggregate(primary, rules, encoder=encoder)
    focused = [c for c in cases if c["focused"]]
    result["focused"] = {
        "cases": len(focused), "facts": sum(len(c["facts"]) for c in focused),
        **{v: {"tokens": sum(count(c, v) for c in focused),
                "retained": sum(sum(c["variants"][v]["visible"]["10000"]["retained"]) for c in focused)}
           for v in ["focused", "pi"]},
    }
    result["median_case_overhead_ms"] = statistics.median(c["latency_pi_minus_native_ms"]["median"] for c in primary)
    result["tee_storage"] = {k: sum(c["tee_storage"][k] for c in cases) for k in ["files", "bytes"]}
    result["streaming"] = {
        v: {metric: statistics.median(row[metric] for row in data["streaming_replay"][v])
            for metric in ["first_byte_ms", "total_ms"]}
        for v in ["native", "pi"]
    }
    result["validation"] = {"outputs_hashed": sum(len(c["variants"]) for c in cases),
                            "exit_status_pairs": len(cases), "facts_recovered_both_arms": result["all"]["facts"]}
    (args.work / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    lines = ["# Command benchmark detail", "", "Generated from the stored command measurements; see the main report for interpretation.", "",
             "Tokens include fixed execution headers and actual pi-rs JSON/recovery markers, using o200k_base after the 10,000 approximate-token Codex cap.", "",
             "| Case | Native tokens | pi-rs tokens | Reduction | Facts native / pi / total | Extra pi latency ms (95% interval) |", "|---|---:|---:|---:|---:|---:|"]
    for c in cases:
        n, p = count(c, "native"), count(c, "pi")
        nf, pf = [sum(c["variants"][v]["visible"]["10000"]["retained"]) for v in ["native", "pi"]]
        latency = c["latency_pi_minus_native_ms"]
        lo, hi = latency["bootstrap_95_ci"]
        lines.append(f"| {c['name']} | {n:,} | {p:,} | {100*(1-p/n):.1f}% | {nf} / {pf} / {len(c['facts'])} | {latency['median']:+.2f} [{lo:+.2f}, {hi:+.2f}] |")
    lines += ["", "Negative reductions mean pi-rs expands the response. Negative latency differences are noisy speedups in this warm-cache sample.",
              "The last five cases are synthetic subprocess replays. All 34 native/pi pairs preserved exit status; pytest_fail intentionally returned 1.",
              "Intervals are bootstrap intervals for paired timing differences, not confidence intervals for task success or token savings.", "",
              "## Recovery at the default cap", "",
              "| Case | Native extra calls | pi-rs extra calls | pi full read still misses target | pi recovery output tokens |", "|---|---:|---:|---|---:|"]
    for c in cases:
        n, p = c["recovery"]["native"], c["recovery"]["pi"]
        if not n["needed"] and not p["needed"]:
            continue
        fail = "yes" if False in p.get("full_read_retained", []) else "no" if "full_read_retained" in p else "not applicable"
        lines.append(f"| {c['name']} | {n['calls']} | {p['calls']} | {fail} | {p['tokens']['o200k_base']:,} |")
    lines += ["", "Every requested fact was available after the measured targeted recovery. Native recovery assumes a previously saved output file. Git history and unchanged-but-Codex-truncated pi responses required a native rerun/filter because pi-rs produced no tee.", "",
              "## Efficient native alternatives", "",
              "These queries are selected with knowledge of the task target; they are not an observed default agent policy.", "",
              "| Case | Native targeted tokens | pi-rs initial tokens | Native targeted command |", "|---|---:|---:|---|"]
    import shlex
    for c in focused:
        command = shlex.join(c["focused"]).replace("|", "&#124;")
        lines.append(f"| {c['name']} | {count(c,'focused'):,} | {count(c,'pi'):,} | `{command}` |")
    (args.work / "command-details.md").write_text("\n".join(lines) + "\n")
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    groups = ["git", "files", "logs", "tests"]
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.4), layout="constrained")
    colors = ["#52677D", "#127B76"]
    for i, v in enumerate(["native", "pi"]):
        y = [j + (i-.5)*.34 for j in range(4)]
        vals = [result["groups"][g][v]["initial_tokens"] / 1000 for g in groups]
        axes[0].barh(y, vals, .32, label="Native" if v=="native" else "pi-rs", color=colors[i])
        for a,b in zip(vals,y):
            axes[0].text(a+.4,b,f"{a:.1f}",va="center",fontsize=9)
        vals = [100*result["groups"][g][v]["retained"]/result["groups"][g]["facts"] for g in groups]
        axes[1].barh(y, vals, .32, color=colors[i])
        for a,b,g in zip(vals,y,groups):
            axes[1].text(min(a+1.5,105),b,f"{result['groups'][g][v]['retained']}/{result['groups'][g]['facts']}",va="center",fontsize=9)
    for ax in axes:
        ax.set_yticks(range(4), ["Git (10)", "Files/search (12)", "Logs (4)", "Tests (3)"])
        ax.invert_yaxis()
        ax.spines[["top", "right"]].set_visible(False)
        ax.grid(axis="x", alpha=.15)
        ax.set_axisbelow(True)
    axes[0].set_xlabel("Initial visible output, thousands of BPE tokens")
    axes[1].set_xlabel("Requested facts present in initial response (%)")
    axes[1].set_xlim(0,125)
    axes[1].set_xticks([0,25,50,75,100])
    axes[0].legend(loc="lower right",frameon=False)
    fig.suptitle("pi-rs 0.2.0: smaller responses can omit useful facts", fontsize=14)
    fig.savefig(args.work / "command-comparison.png",dpi=170)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
