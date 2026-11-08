#!/usr/bin/env python3
"""Run isolated terminal and Go workloads inside a dedicated benchmark VM."""

import argparse
import hashlib
import json
import os
import resource
import shutil
import signal
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path("/bench")
PACKAGES = json.loads(Path("/etc/benchmark-packages.json").read_text())
HERE = Path(__file__).resolve().parent


def command(argv, *, env=None, timeout=90, check=True, cwd=None):
    result = subprocess.run([str(x) for x in argv], env=env, cwd=cwd, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"Command exited {result.returncode}\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}")
    return result


def session_environment(app=None):
    env = os.environ.copy()
    for line in Path("/home/tester/session.env").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    env.update(HOME="/home/tester", USER="tester", LOGNAME="tester", XDG_RUNTIME_DIR="/run/user/1000", DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus")
    if app:
        base = ROOT / "profiles" / app
        for key, leaf in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
            (base / leaf).mkdir(parents=True, exist_ok=True)
            env[key] = str(base / leaf)
        env.update(HERDR_APP_HOME=str(base / "config/herdr-app"), HC_SESSION="vmperf", KERO_HOME=str(base / "data/kero"))
        command(["chown", "-R", "tester:users", base])
    return env


def as_user(argv, env, **kwargs):
    return command(["runuser", "-u", "tester", "--", "env", *[f"{k}={v}" for k, v in env.items()], *argv], cwd=ROOT, **kwargs)


def windows(env):
    return json.loads(as_user(["niri", "msg", "-j", "windows"], env).stdout)


def wait_for(predicate, timeout=45):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise TimeoutError("Benchmark readiness condition timed out")


def processes(uid=None):
    found = {}
    for path in Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            if uid is not None and path.stat().st_uid != uid:
                continue
            raw = (path / "stat").read_text()
            name = raw.split("(", 1)[1].rsplit(")", 1)[0]
            fields = raw.rsplit(")", 1)[1].split()
            found[int(path.name)] = {"name": name, "ppid": int(fields[1]), "ticks": int(fields[11]) + int(fields[12]), "start": int(fields[19]), "rss_kib": int(fields[21]) * os.sysconf("SC_PAGE_SIZE") / 1024}
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    return found


class Monitor:
    def __init__(self, uid=None, parent=None):
        self.uid, self.parent = uid, parent
        self.last = processes(uid)
        self.cpu = {}
        self.peak_rss_kib = 0
        self.stop = threading.Event()
        self.started = time.monotonic()
        self.thread = threading.Thread(target=self.sample_loop)

    def selected(self, current):
        if self.parent is None:
            return current
        ids = {self.parent}
        while True:
            next_ids = ids | {pid for pid, p in current.items() if p["ppid"] in ids}
            if next_ids == ids:
                return {pid: p for pid, p in current.items() if pid in ids}
            ids = next_ids

    def sample(self):
        current = self.selected(processes(self.uid))
        self.peak_rss_kib = max(self.peak_rss_kib, sum(p["rss_kib"] for p in current.values()))
        for pid, proc in current.items():
            before = self.last.get(pid)
            delta = proc["ticks"] - before["ticks"] if before and proc["start"] == before["start"] else proc["ticks"]
            self.cpu[proc["name"]] = self.cpu.get(proc["name"], 0) + max(0, delta)
        self.last = current

    def sample_loop(self):
        while not self.stop.wait(0.05):
            self.sample()

    def __enter__(self):
        self.last = self.selected(processes(self.uid))
        self.thread.start()
        return self

    def __exit__(self, *unused):
        self.stop.set()
        self.thread.join()
        self.sample()

    def result(self):
        hz = os.sysconf("SC_CLK_TCK")
        pss = 0
        for pid in self.last:
            try:
                for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
                    if line.startswith("Pss:"):
                        pss += int(line.split()[1])
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                pass
        return {"observer_seconds": time.monotonic() - self.started, "cpu_seconds": sum(self.cpu.values()) / hz, "cpu_by_process_name": {name: ticks / hz for name, ticks in self.cpu.items()}, "peak_summed_rss_mib": self.peak_rss_kib / 1024, "end_summed_pss_mib": pss / 1024}


def prepare():
    # The creation script attaches one new, empty 32-GiB disk to each VM.
    disks = json.loads(command(["lsblk", "-b", "-J", "-o", "NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS"]).stdout)["blockdevices"]
    candidates = [d for d in disks if d["type"] == "disk" and int(d["size"]) == 32 * 1024**3]
    if len(candidates) != 1:
        raise RuntimeError(f"Expected exactly one new 32-GiB disk: {disks!r}")
    device = "/dev/" + candidates[0]["name"]
    if not os.path.ismount(ROOT):
        if candidates[0].get("fstype") is None and not candidates[0].get("children"):
            command(["mkfs.ext4", "-F", "-L", "vmperf", device])
        elif candidates[0].get("fstype") != "ext4":
            raise RuntimeError("Refusing to overwrite a disk with existing content")
        ROOT.mkdir(exist_ok=True)
        command(["mount", device, ROOT])
    for part in ["runs", "profiles", "go-cache", "gotmp"]:
        (ROOT / part).mkdir(exist_ok=True)
    goroot = Path(command([PACKAGES["go"], "env", "GOROOT"]).stdout.strip())
    if not (ROOT / "goroot").exists():
        shutil.copytree(goroot, ROOT / "goroot", symlinks=False)
        command(["chmod", "-R", "u+w", ROOT / "goroot"])
    # Seed the native welcome state before launching the isolated app.
    app_home = ROOT / "profiles/herdr/config/herdr-app"
    app_home.mkdir(parents=True, exist_ok=True)
    (app_home / "shared.json").write_text(json.dumps({"frame.welcomed": "skipped"}))
    command(["chown", "-R", "tester:users", ROOT])
    env = session_environment()
    egl = as_user(["eglinfo", "-B"], env, check=False).stdout
    section = egl.split("Wayland platform:", 1)[-1].split("X11 platform:", 1)[0]
    metadata = {"packages": PACKAGES, "kernel": command(["uname", "-a"]).stdout, "cpus": os.cpu_count(), "memory": Path("/proc/meminfo").read_text(), "disks": disks, "outputs": json.loads(as_user(["niri", "msg", "-j", "outputs"], env).stdout), "egl_wayland": section, "egl_full": egl, "go_version": command([PACKAGES["go"], "version"]).stdout, "virtualization": command(["systemd-detect-virt"], check=False).stdout.strip()}
    (ROOT / "metadata.json").write_text(json.dumps(metadata, indent=2))
    return metadata


def render_environment(app):
    env = session_environment(app)
    meta = json.loads((ROOT / "metadata.json").read_text())
    mode = "native-gpu"
    if app == "ghostty" and "version: 4.3" not in meta["egl_wayland"] and "version: 4.6" not in meta["egl_wayland"]:
        env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        mode = "llvmpipe-required-for-opengl-4.3"
    if app == "herdr":
        env.update(WGPU_BACKEND="gl", VK_DRIVER_FILES="/dev/null")
    modes = ROOT / "render-modes.json"
    chosen = json.loads(modes.read_text()) if modes.exists() else {}
    if chosen.get(app) == "software-gl":
        env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        mode = "software-gl"
    if chosen.get(app) == "software-vulkan":
        env.pop("VK_DRIVER_FILES", None)
        env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        env["WGPU_BACKEND"] = "vulkan"
        mode = "software-vulkan"
    return env, mode


def app_trial(app, trial, pilot):
    env, mode = render_environment(app)
    # Herdr keeps its core across window launches. Warm this owned session
    # outside the UI startup measurement, including on minimal live systems.
    if app == "herdr":
        status = as_user([PACKAGES["hc"], "server", "status"], env, check=False)
        if status.returncode:
            backend_log = (ROOT / "profiles/herdr/core-bootstrap.log").open("a")
            subprocess.Popen(["runuser", "-u", "tester", "--", "env", *[f"{k}={v}" for k, v in env.items()], PACKAGES["hc"], "serve"], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=backend_log, stderr=backend_log, start_new_session=True)
            backend_log.close()
            wait_for(lambda: as_user([PACKAGES["hc"], "server", "status"], env, check=False).returncode == 0)
    app_id = {"ghostty": "com.mitchellh.ghostty", "herdr": "herdr-app", "kero": "kero"}[app]
    results = {"kind": "app", "app": app, "trial": trial, "pilot": pilot, "render_mode": mode, "phases": [], "errors": []}
    for phase in ["idle", "bulk", "paced"]:
        directory = ROOT / "runs" / f"{app}-{trial}-{phase}"
        directory.mkdir(parents=True, exist_ok=False)
        command(["chown", "tester:users", directory])
        child = [PACKAGES["python"], str(HERE / "terminal_workload.py"), str(directory), phase, "--frames", "60" if pilot else "480", "--lines", "10000" if pilot else "100000"]
        log = (directory / "app.log").open("w")
        started = time.monotonic_ns()
        target = None
        process = None
        try:
            argv = [PACKAGES[app]]
            if app == "ghostty":
                argv += ["--config-default-files=false", "--gtk-single-instance=false", "--font-family=DejaVu Sans Mono", "--font-size=14", "-e", *child]
            process = subprocess.Popen(["runuser", "-u", "tester", "--", "env", *[f"{k}={v}" for k, v in env.items()], *argv], cwd=ROOT, stdout=log, stderr=log, start_new_session=True)
            def own_window():
                if process.poll() is not None:
                    raise RuntimeError(f"{app} exited before opening its window: {(directory / 'app.log').read_text()[-2000:]}")
                return next((w for w in windows(env) if w["app_id"] == app_id), None)
            win = wait_for(own_window)
            as_user(["niri", "msg", "action", "focus-window", "--id", str(win["id"])], env)
            if app == "herdr":
                wait_for(lambda: as_user([PACKAGES[app], "status"], env, check=False).returncode == 0)
                value = json.loads(as_user([PACKAGES[app], "do", "space.new", json.dumps({"name": f"bench-{trial}-{phase}", "folder": str(ROOT), "tab": "benchmark", "argv": child})], env).stdout)
                target = value["space"]
            elif app == "kero":
                target = as_user([PACKAGES[app], "new", "-n", f"bench-{trial}-{phase}", "-d", str(ROOT), "--", *child], env).stdout.strip()
            ready = wait_for(lambda: json.loads((directory / "ready.json").read_text()) if (directory / "ready.json").exists() else None)
            wait_for(lambda: (directory / "prepared").exists())
            with Monitor(uid=1000) as monitor:
                (directory / "start").touch()
                measured = wait_for(lambda: json.loads((directory / "result.json").read_text()) if (directory / "result.json").exists() else None, timeout=180)
            if measured.get("error"):
                raise RuntimeError(measured["error"])
            measured.update(monitor.result())
            measured["startup_seconds"] = (ready["monotonic_ns"] - started) / 1e9
            measured["terminal_size"] = ready["size"]
            measured["log"] = str(directory / "app.log")
            # Save a correctness image separately, outside the measured region.
            as_user(["niri", "msg", "action", "screenshot-window", "--id", str(win["id"]), "--path", str(directory / "window.png")], env)
            actual_pid = win["pid"]
            measured["graphics_environment"] = {k: v for k, v in env.items() if k.startswith(("LIBGL_", "VK_", "WGPU_", "MYGO_"))}
            measured["gpu_fds"] = [str(p.resolve()) for p in Path(f"/proc/{actual_pid}/fd").iterdir() if p.is_symlink() and "/dev/dri/" in str(p.resolve())]
            measured["graphics_libraries"] = sorted({line.split()[-1] for line in Path(f"/proc/{actual_pid}/maps").read_text().splitlines() if any(s in line for s in ["libgallium", "libEGL_mesa", "libvulkan_lvp"])})
            results["phases"].append(measured)
        finally:
            (directory / "release").touch()
            if target and app == "herdr":
                closed = as_user([PACKAGES[app], "do", "space.close", json.dumps({"id": target, "confirmed": True})], env, check=False)
                if closed.returncode:
                    results["errors"].append({"phase": phase, "cleanup": closed.stdout + closed.stderr})
                # A normal close flushes layout state; SIGTERM can resurrect
                # a just-closed space on the next launch.
                as_user([PACKAGES[app], "do", "window.close"], env, check=False)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    results["errors"].append({"phase": phase, "cleanup": "window.close did not exit"})
            if target and app == "kero":
                as_user([PACKAGES[app], "close", target], env, check=False)
            if process and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            log.close()
    return results


def go_trial(trial, profile=False):
    directory = ROOT / "runs" / f"go-{trial}"
    directory.mkdir(exist_ok=False)
    cache = ROOT / "go-cache" / str(trial)
    cache.mkdir()
    env = os.environ | {"GOROOT": str(ROOT / "goroot"), "GOCACHE": str(cache), "GOTMPDIR": str(ROOT / "gotmp"), "GOTOOLCHAIN": "local", "GOPROXY": "off", "GOSUMDB": "off", "GO111MODULE": "off", "CGO_ENABLED": "0", "GOMAXPROCS": "8"}
    if command([PACKAGES["go"], "env", "GOROOT"], env=env).stdout.strip() != env["GOROOT"]:
        raise RuntimeError("Go is not using the isolated source tree")
    stamp = ROOT / "goroot/src/cmd/compile/vm_benchmark_stamp.go"
    binary = directory / "compile"
    records = []
    for phase in ["clean", "incremental"]:
        token = f"trial-{trial}-{phase}"
        stamp.write_text('package main\nimport ("os"; "fmt")\nfunc init() { if len(os.Args)==2 && os.Args[1]=="-vm-bench-stamp" { fmt.Println("' + token + '"); os.Exit(0) } }\n')
        argv = [PACKAGES["go"], "build", "-p=8", "-trimpath", "-o", str(binary)]
        if profile and phase == "clean":
            argv += ["-gcflags=cmd/compile/internal/ssa=-cpuprofile=" + str(directory / "ssa.pprof")]
        argv += ["cmd/compile"]
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        started = time.monotonic()
        with (directory / f"{phase}.log").open("w") as log:
            proc = subprocess.Popen(argv, env=env, stdout=log, stderr=log)
            with Monitor(parent=proc.pid) as monitor:
                code = proc.wait(timeout=600)
        elapsed = time.monotonic() - started
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        if code:
            raise RuntimeError((directory / f"{phase}.log").read_text()[-4000:])
        if command([binary, "-vm-bench-stamp"]).stdout.strip() != token:
            raise RuntimeError("The compiler did not incorporate the changed source")
        version = command([binary, "-V"]).stdout.strip()
        (directory / "tiny.go").write_text("package proof\nfunc Sum[T ~int](a, b T) T { return a+b }\nvar Answer = Sum(20,22)\n")
        command([binary, "-o", str(directory / "tiny.o"), str(directory / "tiny.go")])
        members = command([PACKAGES["go"], "tool", "pack", "t", str(directory / "tiny.o")], env=env).stdout
        if "_go_.o" not in members:
            raise RuntimeError("The rebuilt compiler did not produce a valid object")
        records.append({"phase": phase, "seconds": elapsed, "user_seconds": after.ru_utime - before.ru_utime, "system_seconds": after.ru_stime - before.ru_stime, "exit_code": code, "version": version, "stamp": token, "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "object_members": members, "resources": monitor.result()})
    if profile:
        (directory / "profile-top.txt").write_text(command([PACKAGES["go"], "tool", "pprof", "-top", "-nodecount=15", str(directory / "ssa.pprof")], env=env).stdout)
    return {"kind": "go", "trial": trial, "profile": profile, "target": "cmd/compile", "phases": records, "errors": []}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "app", "go", "profile-go"])
    parser.add_argument("--app", choices=["ghostty", "herdr", "kero"])
    parser.add_argument("--trial", type=int, default=0)
    parser.add_argument("--pilot", action="store_true")
    args = parser.parse_args()
    if args.action == "prepare":
        result = prepare()
    elif args.action == "app":
        result = app_trial(args.app, args.trial, args.pilot)
    else:
        result = go_trial(args.trial, profile=args.action == "profile-go")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
