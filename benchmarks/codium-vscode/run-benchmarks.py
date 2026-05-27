#!/usr/bin/env python3
"""Run VSCodium / VS Code wall-clock comparison probes.

Mirrors benchmarks/vm-host-performance/run-benchmarks.py: shell wall-clock
loops, mean/median/min/max, raw JSON suitable for a report under
reports/codium-vscode-vm-vs-macos.md.

All workloads are headless CLI invocations so they run identically over SSH
on Linux and macOS — no display server, no GUI window.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path


# Pinned VSIX so the install/uninstall workloads do not hit the network
# inside the measured loop and pull the same artifact on both editors.
# Open VSX is used because (a) it ships VSCodium's default catalog and
# (b) VS Code is happy to install any VSIX from a local file path.
EDITORCONFIG_VSIX_URL = (
    "https://open-vsx.org/api/EditorConfig/EditorConfig/0.18.2/file/"
    "EditorConfig.EditorConfig-0.18.2.vsix"
)
EDITORCONFIG_VSIX_NAME = "EditorConfig.EditorConfig-0.18.2.vsix"
EDITORCONFIG_EXT_ID = "editorconfig.editorconfig"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--binary",
        default=os.environ.get("CODE_BIN") or default_binary(),
        help="Path to codium/code CLI (default: codium on Linux, "
        "/Applications/Visual Studio Code.app/.../code on macOS, "
        "or $CODE_BIN if set)",
    )
    parser.add_argument("--out", required=True, help="Output JSON path")
    parser.add_argument("--label", required=True, help="Human-readable machine label")
    parser.add_argument(
        "--work",
        default="/tmp/codium-bench-work",
        help="Working directory for tmp profiles, extension dirs, VSIX cache",
    )
    return parser.parse_args()


def default_binary() -> str:
    mac_default = (
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    )
    if sys.platform == "darwin" and Path(mac_default).exists():
        return mac_default
    return "codium"


def capture(cmd: str, cwd: str | None = None, timeout: int = 30) -> dict[str, object]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            shell=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return {
            "code": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        }
    except Exception as exc:  # noqa: BLE001
        return {"code": -1, "stdout": "", "stderr": repr(exc)}


def run_once(command: str, cwd: str, timeout: int = 120) -> dict[str, object]:
    start_wall = time.perf_counter()
    start_proc = time.process_time()
    try:
        proc = subprocess.run(
            command,
            cwd=cwd,
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        rc = proc.returncode
        stderr_tail = proc.stderr[-2000:]
    except subprocess.TimeoutExpired as exc:
        rc = -1
        stderr_tail = f"timeout after {exc.timeout}s"
    end_proc = time.process_time()
    end_wall = time.perf_counter()
    return {
        "wall": end_wall - start_wall,
        "runner_cpu": end_proc - start_proc,
        "code": rc,
        "stderr_tail": stderr_tail,
    }


def ensure_vsix_cache(work: Path) -> Path:
    """Download the pinned VSIX once. Reused by every install/uninstall run."""
    cache = work / "vsix-cache"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / EDITORCONFIG_VSIX_NAME
    if target.exists() and target.stat().st_size > 0:
        return target
    print(f"  fetching {EDITORCONFIG_VSIX_URL}", flush=True)
    # curl rather than urllib so we inherit the OS trust store. Python's
    # bundled CA set rejects some intermediates that curl accepts cleanly.
    rc = subprocess.run(
        ["curl", "-fsSL", "-o", str(target), EDITORCONFIG_VSIX_URL],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if rc.returncode != 0 or not target.exists() or target.stat().st_size == 0:
        raise RuntimeError(
            f"failed to fetch VSIX: rc={rc.returncode} "
            f"stderr={rc.stderr.decode(errors='replace')[-500:]}"
        )
    return target


def ensure_preloaded_extdir(work: Path, binary: str, vsix: Path) -> Path:
    """Build an extensions dir with editorconfig already installed.

    Used by `list-extensions (preloaded)` and `uninstall-extension`. Kept on
    disk between runs because we only need its final shape, not the time to
    create it.
    """
    preloaded = work / "ext-preloaded"
    marker = preloaded / ".ready"
    if marker.exists():
        return preloaded
    if preloaded.exists():
        shutil.rmtree(preloaded)
    preloaded.mkdir(parents=True)
    # Use a fresh user-data-dir to avoid touching the real profile.
    udd = work / "udd-setup"
    udd.mkdir(parents=True, exist_ok=True)
    cmd = (
        f'"{binary}" --user-data-dir "{udd}" --extensions-dir "{preloaded}" '
        f'--install-extension "{vsix}"'
    )
    rc = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if rc.returncode != 0:
        raise RuntimeError(
            f"failed to preload extension: rc={rc.returncode} "
            f"stderr={rc.stderr.decode(errors='replace')[-500:]}"
        )
    marker.write_text("ok\n")
    return preloaded


def make_workloads(binary: str, work: Path, vsix: Path, preloaded: Path) -> list[dict[str, object]]:
    udd_pool = work / "udd-pool"
    ext_fresh = work / "ext-fresh"
    ext_preloaded_scratch = work / "ext-preloaded-scratch"
    udd_pool.mkdir(parents=True, exist_ok=True)

    # Stable per-workload user-data-dir keeps disk warm but isolates from
    # the user's real profile. Each workload that needs a fresh state
    # mutates its own dir inside the shell command.
    def udd(name: str) -> Path:
        p = udd_pool / name
        p.mkdir(parents=True, exist_ok=True)
        return p

    # Quoted argv-style command builder. shell=True is fine because every
    # path is generated by us, no user input.
    def cli(args: list[str]) -> str:
        return " ".join(['"{}"'.format(binary)] + args)

    return [
        {
            "id": "version",
            "category": "Bootstrap",
            "description": "`code --version` (Node + V8 bootstrap, no engine)",
            "command": cli(["--version"]) + " 2>/dev/null",
            "warmups": 3,
            "runs": 20,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "list_extensions_empty",
            "category": "Bootstrap",
            "description": "list-extensions against a fresh empty extensions dir",
            "command": (
                f'D="{ext_fresh}/le-empty"; rm -rf "$D" && mkdir -p "$D" && '
                + cli([
                    f'--user-data-dir "{udd("le_empty")}"',
                    '--extensions-dir "$D"',
                    "--list-extensions",
                ])
                + " 2>/dev/null"
            ),
            "warmups": 2,
            "runs": 15,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "list_extensions_preloaded",
            "category": "Bootstrap",
            "description": "list-extensions against a dir with 1 extension installed",
            "command": cli([
                f'--user-data-dir "{udd("le_pre")}"',
                f'--extensions-dir "{preloaded}"',
                "--list-extensions",
            ]) + " 2>/dev/null",
            "warmups": 2,
            "runs": 15,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "install_extension_from_vsix",
            "category": "Install pipeline",
            "description": "install pinned EditorConfig VSIX into a fresh extensions dir",
            "command": (
                f'D="{ext_fresh}/install"; rm -rf "$D" && mkdir -p "$D" && '
                + cli([
                    f'--user-data-dir "{udd("install")}"',
                    '--extensions-dir "$D"',
                    f'--install-extension "{vsix}"',
                ])
                + " 2>/dev/null"
            ),
            "warmups": 1,
            "runs": 8,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "uninstall_extension",
            "category": "Install pipeline",
            "description": (
                "uninstall EditorConfig from a freshly-cloned preloaded ext dir"
            ),
            "command": (
                f'D="{ext_preloaded_scratch}"; rm -rf "$D" && '
                f'cp -R "{preloaded}" "$D" && '
                + cli([
                    f'--user-data-dir "{udd("uninstall")}"',
                    '--extensions-dir "$D"',
                    f"--uninstall-extension {EDITORCONFIG_EXT_ID}",
                ])
                + " 2>/dev/null"
            ),
            "warmups": 1,
            "runs": 8,
            "unit": "s",
            "better": "lower",
        },
    ]


def metadata(label: str, binary: str) -> dict[str, object]:
    # Strip Electron --argv warnings from stderr so the metadata reads cleanly.
    return {
        "label": label,
        "binary": binary,
        "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": sys.version.split()[0],
        "hostname": capture("hostname"),
        "uname": capture("uname -a"),
        "virtualization": capture("systemd-detect-virt -v 2>/dev/null || true"),
        "code_version": capture(f'"{binary}" --version 2>/dev/null'),
        "node_version": capture("node --version 2>/dev/null"),
        "cpu_summary": capture(
            "lscpu 2>/dev/null | sed -n '1,25p' || "
            "sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize "
            "hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu 2>/dev/null || true"
        ),
        "memory_summary": capture(
            "free -h 2>/dev/null || vm_stat 2>/dev/null | head -20 || true"
        ),
        "disk_summary": capture(
            "lsblk -o NAME,TYPE,SIZE,MODEL,ROTA,SCHED,FSTYPE,MOUNTPOINTS 2>/dev/null || "
            "diskutil info / 2>/dev/null | egrep "
            "'File System|Protocol|Solid State|Volume Total Space|Device / Media Name|APFS' || true"
        ),
        "mount_summary": capture(
            "mount | egrep ' on / | on /nix | on /tmp | on /home|/Users' | head -20 || true"
        ),
    }


def main() -> None:
    args = parse_args()
    binary = args.binary
    if not Path(binary).exists() and shutil.which(binary) is None:
        sys.exit(f"binary not found: {binary}")

    work = Path(args.work).expanduser().resolve()
    work.mkdir(parents=True, exist_ok=True)
    print(f"[{args.label}] binary={binary}")
    print(f"[{args.label}] work={work}")

    vsix = ensure_vsix_cache(work)
    preloaded = ensure_preloaded_extdir(work, binary, vsix)

    results: list[dict[str, object]] = []
    for workload in make_workloads(binary, work, vsix, preloaded):
        print(f"[{args.label}] {workload['id']}", flush=True)
        for _ in range(int(workload["warmups"])):
            run_once(str(workload["command"]), str(work))

        runs = []
        for _ in range(int(workload["runs"])):
            result = run_once(str(workload["command"]), str(work))
            runs.append(result)
            if result["code"] != 0:
                break

        ok_runs = [float(r["wall"]) for r in runs if r["code"] == 0]
        entry = {**workload, "runs_raw": runs}
        if len(ok_runs) == len(runs) and ok_runs:
            entry.update(
                {
                    "mean": statistics.mean(ok_runs),
                    "median": statistics.median(ok_runs),
                    "stdev": statistics.stdev(ok_runs) if len(ok_runs) > 1 else 0.0,
                    "min": min(ok_runs),
                    "max": max(ok_runs),
                    "runs_completed": len(ok_runs),
                }
            )
        else:
            entry["error"] = runs[-1]["stderr_tail"] if runs else "no runs"
        results.append(entry)

    out = {
        "metadata": metadata(args.label, binary),
        "results": results,
        "config": {
            "vsix_url": EDITORCONFIG_VSIX_URL,
            "vsix_path": str(vsix),
            "preloaded_ext_dir": str(preloaded),
            "work": str(work),
        },
    }
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2))
    print(f"wrote {out_path}", flush=True)


if __name__ == "__main__":
    main()
