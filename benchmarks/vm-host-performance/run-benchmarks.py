#!/usr/bin/env python3
"""Run comparable VM-vs-macOS performance probes.

This script intentionally avoids sudo-only profilers. It runs simple
wall-clock workloads that can execute unchanged on NixOS/aarch64-linux and
nix-darwin/aarch64-darwin, then writes raw JSON suitable for the report in
reports/vm-vs-macos-performance.md.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import textwrap
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".", help="Path to this nix repo")
    parser.add_argument("--out", required=True, help="Output JSON path")
    parser.add_argument("--label", required=True, help="Human-readable machine label")
    return parser.parse_args()


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
    except Exception as exc:  # noqa: BLE001 - preserve diagnostics in JSON
        return {"code": -1, "stdout": "", "stderr": repr(exc)}


def run_once(command: str, cwd: str) -> dict[str, object]:
    start_wall = time.perf_counter()
    start_proc = time.process_time()
    proc = subprocess.run(
        command,
        cwd=cwd,
        shell=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    end_proc = time.process_time()
    end_wall = time.perf_counter()
    return {
        "wall": end_wall - start_wall,
        "runner_cpu": end_proc - start_proc,
        "code": proc.returncode,
        "stderr_tail": proc.stderr[-2000:],
    }


def write_helper_scripts(work: Path) -> dict[str, str]:
    work.mkdir(parents=True, exist_ok=True)
    scripts: dict[str, str] = {}

    def write_script(name: str, content: str) -> None:
        path = work / name
        path.write_text(textwrap.dedent(content).lstrip())
        path.chmod(0o755)
        scripts[name] = str(path)

    write_script(
        "python_cpu_int.py",
        r'''
        #!/usr/bin/env python3
        acc = 0x12345678
        for i in range(15_000_000):
            acc = ((acc * 1664525) + i + 1013904223) & 0xffffffffffffffff
        print(acc)
        ''',
    )

    write_script(
        "python_mem_touch.py",
        r'''
        #!/usr/bin/env python3
        n = 512 * 1024 * 1024
        b = bytearray(n)
        step = 4096
        for i in range(0, n, step):
            b[i] = (i // step) & 0xff
        s = 0
        for i in range(0, n, 1024 * 1024):
            s += b[i]
        print(s)
        ''',
    )

    write_script(
        "fs_seq_rw.py",
        r'''
        #!/usr/bin/env python3
        import os
        import random

        path = "/tmp/vm-host-perf-work/seq-rw.bin"
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        rng = random.Random(12345)
        chunk = rng.randbytes(1024 * 1024)
        with open(path, "wb", buffering=0) as f:
            for _ in range(512):
                f.write(chunk)
            os.fsync(f.fileno())
        total = 0
        with open(path, "rb", buffering=0) as f:
            while True:
                data = f.read(1024 * 1024)
                if not data:
                    break
                total += data[0]
        os.unlink(path)
        print(total)
        ''',
    )

    write_script(
        "fs_smallfiles.py",
        r'''
        #!/usr/bin/env python3
        import os
        import shutil

        root = "/tmp/vm-host-perf-work/smallfiles"
        shutil.rmtree(root, ignore_errors=True)
        os.mkdir(root)
        payload = b"x" * 128
        for i in range(5000):
            with open(f"{root}/{i:05d}.txt", "wb") as f:
                f.write(payload)
        total = 0
        for name in os.listdir(root):
            path = f"{root}/{name}"
            st = os.stat(path)
            total += st.st_size
            with open(path, "rb") as f:
                total += f.read(1)[0]
        shutil.rmtree(root)
        print(total)
        ''',
    )

    return scripts


def make_workloads(repo: Path, scripts: dict[str, str]) -> list[dict[str, object]]:
    file_to_open = repo / "home/cli/nvim-lazyvim.nix"
    cargo_command = "cargo check --quiet >/dev/null"
    if os.environ.get("LIBICONV_LIB"):
        cargo_command = f'LIBRARY_PATH="{os.environ["LIBICONV_LIB"]}" {cargo_command}'

    return [
        {
            "id": "nvim_clean_open_close",
            "category": "Editor/process",
            "description": "Neovim clean startup and immediate quit",
            "command": "nvim --clean --headless +qa",
            "cwd": str(repo),
            "warmups": 3,
            "runs": 20,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "nvim_config_open_close",
            "category": "Editor/process",
            "description": "Configured Neovim startup and immediate quit",
            "command": "nvim --headless +qa",
            "cwd": str(repo),
            "warmups": 3,
            "runs": 20,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "nvim_open_nix_file_close",
            "category": "Editor/file open",
            "description": "Configured Neovim opens nvim-lazyvim.nix and quits",
            "command": f'nvim --headless +"edit {file_to_open}" +qa',
            "cwd": str(repo),
            "warmups": 3,
            "runs": 20,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "repo_ripgrep_search",
            "category": "Search/metadata",
            "description": "ripgrep over repo for NixOS/VM terms",
            "command": "rg --hidden --glob '!.git' --glob '!result' --glob '!result-*' --glob '!home/cli/pi-rs/.bench-*' -n 'nixos|parallels|neovim|systemd' . >/dev/null",
            "cwd": str(repo),
            "warmups": 2,
            "runs": 15,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "nix_eval_systemd_services_attrnames",
            "category": "Nix/evaluation",
            "description": "Evaluate service names from prl-dev-vm NixOS config",
            "command": "nix eval --json .#nixosConfigurations.prl-dev-vm.config.systemd.services --apply builtins.attrNames >/dev/null",
            "cwd": str(repo),
            "warmups": 1,
            "runs": 7,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "openssl_sha256_1g_file",
            "category": "CPU/crypto",
            "description": "OpenSSL hashes cached 1 GiB file with SHA-256",
            "command": "openssl dgst -sha256 /tmp/vm-host-perf-work/hash-1g.bin >/dev/null",
            "setup": "python3 -c \"from pathlib import Path; p = Path('/tmp/vm-host-perf-work/hash-1g.bin'); p.parent.mkdir(parents=True, exist_ok=True); size = 1024 * 1024 * 1024; chunk = bytes((i % 251 for i in range(1024 * 1024))); (not p.exists() or p.stat().st_size != size) and p.write_bytes(chunk * 1024)\"",
            "cwd": str(repo),
            "warmups": 1,
            "runs": 5,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "python_integer_loop",
            "category": "CPU/interpreter",
            "description": "Python integer loop, 15M iterations",
            "command": f'python3 {scripts["python_cpu_int.py"]} >/dev/null',
            "cwd": str(repo),
            "warmups": 1,
            "runs": 7,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "python_alloc_touch_512m",
            "category": "Memory/page faults",
            "description": "Python allocate and touch 512 MiB bytearray",
            "command": f'python3 {scripts["python_mem_touch.py"]} >/dev/null',
            "cwd": str(repo),
            "warmups": 1,
            "runs": 7,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "fs_tmp_seq_write_read_512m",
            "category": "Filesystem/sequential",
            "description": "Write+fsync+read 512 MiB file in /tmp",
            "command": f'python3 {scripts["fs_seq_rw.py"]} >/dev/null',
            "cwd": str(repo),
            "warmups": 1,
            "runs": 5,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "fs_tmp_smallfiles_5000",
            "category": "Filesystem/metadata",
            "description": "Create/stat/read/delete 5k tiny files in /tmp",
            "command": f'python3 {scripts["fs_smallfiles.py"]} >/dev/null',
            "cwd": str(repo),
            "warmups": 1,
            "runs": 7,
            "unit": "s",
            "better": "lower",
        },
        {
            "id": "cargo_pi_rs_check_cached",
            "category": "Dev/Rust",
            "description": "Cached cargo check for home/cli/pi-rs",
            "command": cargo_command,
            "cwd": str(repo / "home/cli/pi-rs"),
            "warmups": 1,
            "runs": 5,
            "unit": "s",
            "better": "lower",
        },
    ]


def metadata(label: str, repo: Path) -> dict[str, object]:
    return {
        "label": label,
        "repo": str(repo),
        "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": sys.version.split()[0],
        "hostname": capture("hostname"),
        "uname": capture("uname -a"),
        "virtualization": capture("systemd-detect-virt -v 2>/dev/null || true"),
        "nvim_version": capture("nvim --version | head -1"),
        "openssl_version": capture("openssl version"),
        "python_version": capture("python3 --version"),
        "node_version": capture("node --version"),
        "bun_version": capture("bun --version"),
        "cargo_version": capture("cargo --version"),
        "rustc_version": capture("rustc --version"),
        "rg_version": capture("rg --version | head -1"),
        "nix_version": capture("nix --version"),
        "cpu_summary": capture("lscpu 2>/dev/null | sed -n '1,25p' || sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu 2>/dev/null || true"),
        "memory_summary": capture("free -h 2>/dev/null || vm_stat 2>/dev/null | head -20 || true"),
        "disk_summary": capture("lsblk -o NAME,TYPE,SIZE,MODEL,ROTA,SCHED,FSTYPE,MOUNTPOINTS 2>/dev/null || diskutil info / 2>/dev/null | egrep 'File System|Protocol|Solid State|Volume Total Space|Device / Media Name|APFS' || true"),
        "mount_summary": capture("mount | egrep ' on / | on /nix | on /tmp | on /home|/Users' | head -20 || true"),
        "ptrace_scope": capture("/run/current-system/sw/bin/coreutils --coreutils-prog=cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || true"),
    }


def main() -> None:
    args = parse_args()
    repo = Path(args.repo).expanduser().resolve()
    work = Path("/tmp/vm-host-perf-work")
    scripts = write_helper_scripts(work)
    results: list[dict[str, object]] = []

    for workload in make_workloads(repo, scripts):
        cwd = str(workload["cwd"])
        if not Path(cwd).exists():
            results.append({**workload, "error": f"cwd missing: {cwd}"})
            continue

        print(f"[{args.label}] {workload['id']}", flush=True)
        if workload.get("setup"):
            setup_result = run_once(str(workload["setup"]), cwd)
            if setup_result["code"] != 0:
                results.append({**workload, "error": setup_result["stderr_tail"]})
                continue

        for _ in range(int(workload["warmups"])):
            run_once(str(workload["command"]), cwd)

        runs = []
        for _ in range(int(workload["runs"])):
            result = run_once(str(workload["command"]), cwd)
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

    out = {"metadata": metadata(args.label, repo), "results": results}
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2))
    print(f"wrote {out_path}", flush=True)


if __name__ == "__main__":
    main()
