#!/usr/bin/env python3
"""User-triggered nix-darwin build, followed by macOS GUI-authorized activation."""

import argparse
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import sys

RUNNING = {"starting", "building", "applying"}


class TimestampLog:
    def __init__(self, stream, now=None):
        self.stream = stream
        self.now = now or (lambda: datetime.now().astimezone())

    def write(self, text):
        for line in text.splitlines():
            if line:
                stamp = self.now().isoformat(timespec="seconds")
                self.stream.write(f"[{stamp}] {line}\n")
            else:
                self.stream.write("\n")
        self.stream.flush()
        return len(text)

    def flush(self):
        self.stream.flush()


def logged_run(argv, log, capture_stdout=False, capture_stderr=False, **kwargs):
    # Drain both pipes together: Nix's JSON stdout stays untouched while
    # stderr is timestamped, and verbose children cannot deadlock either pipe.
    captured_out = bytearray()
    captured_err = bytearray()
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs) as process:
        try:
            with selectors.DefaultSelector() as reader:
                for stream in (process.stdout, process.stderr):
                    reader.register(stream, selectors.EVENT_READ, bytearray())
                while reader.get_map():
                    for key, _ in reader.select():
                        data = os.read(key.fd, 65536)
                        is_stdout = key.fileobj is process.stdout
                        if capture_stdout and is_stdout:
                            captured_out.extend(data)
                        else:
                            if capture_stderr and not is_stdout:
                                captured_err.extend(data)
                            key.data.extend(data)
                            while b"\n" in key.data:
                                line, _, rest = key.data.partition(b"\n")
                                log.write(line.decode("utf-8", errors="replace") + "\n")
                                key.data[:] = rest
                        if not data:
                            if key.data:
                                log.write(key.data.decode("utf-8", errors="replace"))
                            reader.unregister(key.fileobj)
            process.wait()
        except BaseException:
            try:
                process.kill()
            except PermissionError:
                pass
            process.communicate()
            raise
        return subprocess.CompletedProcess(
            argv,
            process.returncode,
            captured_out.decode("utf-8", errors="replace"),
            captured_err.decode("utf-8", errors="replace"),
        )


class DarwinRebuilder:
    def __init__(self, config, config_path, state_dir=None):
        self.config = config
        self.config_path = str(config_path)
        self.repository = Path(config["repository"])
        self.state_dir = Path(
            state_dir
            or (
                Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
                / "darwin-nix-rebuild"
            )
        )
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state_file = self.state_dir / "status.json"
        self.log_file = self.state_dir / "rebuild.log"
        self.run_lock_file = self.state_dir / "run.lock"
        self.current_system = Path("/run/current-system")

    def command(self, name, *args, log=None, capture_stdout=False, capture_stderr=False, **kwargs):
        argv = [self.config[name], *map(str, args)]
        if log is not None:
            return logged_run(
                argv,
                log,
                capture_stdout=capture_stdout,
                capture_stderr=capture_stderr,
                **kwargs,
            )
        return subprocess.run(argv, **kwargs)

    def dirty(self):
        result = self.command(
            "git",
            "-C",
            self.repository,
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=normal",
            capture_output=True,
            timeout=10,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        )
        if result.returncode:
            raise ValueError("Cannot read the Nix checkout's Git status.")
        return bool(result.stdout)

    def job_active(self):
        with self.run_lock_file.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(lock, fcntl.LOCK_UN)
            return False

    def gui_session_available(self):
        result = self.command(
            "launchctl",
            "managername",
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.returncode == 0 and result.stdout.strip() == "Aqua"

    def read_state(self):
        try:
            value = json.loads(self.state_file.read_text())
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def save(self, phase, message, **extra):
        temporary = self.state_dir / "status.json.tmp"
        temporary.write_text(json.dumps({"phase": phase, "message": message, **extra}))
        temporary.replace(self.state_file)

    def notify(self, message, error=False):
        title = "nix-darwin rebuild failed" if error else "nix-darwin rebuild"
        try:
            self.command(
                "osascript",
                "-e",
                "on run argv",
                "-e",
                "display notification (item 1 of argv) with title (item 2 of argv)",
                "-e",
                "end run",
                "--",
                message,
                title,
                capture_output=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            pass  # A notification failure must not alter the build/activation result.

    def status(self):
        state = self.read_state()
        error = None
        try:
            dirty = self.dirty()
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            dirty, error = False, str(exc)
        try:
            busy = self.job_active()
        except OSError as exc:
            busy, error = True, error or str(exc)
        if busy and state.get("phase") not in RUNNING:
            state = {"phase": "starting", "message": "Rebuild job is starting or finishing."}
        elif not busy and state.get("phase") in RUNNING:
            state = {
                "phase": "interrupted",
                "message": "Rebuild job stopped; inspect the log before retrying.",
            }
        return {
            **state,
            "dirty": dirty,
            "busy": busy,
            "error": error,
            "repository": str(self.repository),
            "log": str(self.log_file),
        }

    def spawn_runner(self, ready_fd):
        return subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--config",
                self.config_path,
                "run",
                "--ready-fd",
                str(ready_fd),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            pass_fds=(ready_fd,),
        )

    def start(self):
        with (self.state_dir / "launch.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if self.job_active():
                return {"started": False, "busy": True}
            if not self.dirty():
                return {"started": False, "busy": False, "message": "Nix checkout is clean."}
            ready_r, ready_w = os.pipe()
            try:
                proc = self.spawn_runner(ready_w)
            except BaseException:
                os.close(ready_r)
                os.close(ready_w)
                raise
            os.close(ready_w)
            try:
                ready = os.read(ready_r, 16)
            finally:
                os.close(ready_r)
            if ready != b"ok":
                rc = proc.poll()
                raise ValueError(
                    f"Could not start the rebuild job (child exited with {rc})."
                )
            return {"started": True, "busy": True}

    @staticmethod
    def built_system(stdout):
        try:
            outputs = json.loads(stdout)
            if not isinstance(outputs, list) or len(outputs) != 1:
                raise ValueError
            path = outputs[0]["outputs"]["out"]
            pattern = r"/nix/store/[0-9a-z]{32}-darwin-system-[^/\s]+"
            if not isinstance(path, str) or not re.fullmatch(pattern, path):
                raise ValueError
            return path
        except (ValueError, KeyError, TypeError) as exc:
            raise ValueError(
                "Build did not return exactly one darwin system closure for this host."
            ) from exc

    def activate_command_string(self, system):
        return f"{shlex.quote(self.config['activator'])} {shlex.quote(system)} 2>&1"

    def run(self, ready_fd=None):
        if os.geteuid() == 0:
            raise ValueError("Run the build as your normal user, not root.")
        with self.run_lock_file.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if ready_fd is not None:
                try:
                    os.write(ready_fd, b"ok")
                finally:
                    os.close(ready_fd)
            with self.log_file.open("w") as stream:
                log = TimestampLog(stream)
                try:
                    if not self.dirty():
                        self.save("idle", "Nix checkout is clean; nothing was started.")
                        return 0
                    self.save("building", "Building the nix-darwin system as your normal user.")
                    log.write(
                        "Building the current tracked Nix checkout. Untracked files are NOT staged automatically.\n"
                    )
                    log.flush()
                    host = self.config["hostname"]
                    result = self.command(
                        "nix",
                        "build",
                        "--json",
                        "--no-write-lock-file",
                        "--print-build-logs",
                        "--out-link",
                        self.state_dir / "result",
                        str(self.repository) + "#darwinConfigurations." + host + ".system",
                        log=log,
                        capture_stdout=True,
                    )
                    if result.returncode:
                        raise ValueError("System build failed. Inspect the rebuild log.")
                    system = self.built_system(result.stdout)
                    if not self.gui_session_available():
                        raise ValueError(
                            "No macOS Aqua GUI session is available for administrator authentication."
                        )
                    self.save(
                        "applying",
                        "Authenticate in the macOS GUI dialog to apply the built system.",
                        system=system,
                    )
                    log.write("\nApplying the exact built closure: " + system + "\n")
                    log.flush()
                    self.notify(
                        "Build ready. Authenticate in the GUI dialog to apply it; cancel to keep the current system."
                    )
                    prompt = f"Apply nix-darwin configuration ({host})"
                    result = self.command(
                        "osascript",
                        "-e",
                        "on run argv",
                        "-e",
                        "do shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)",
                        "-e",
                        "end run",
                        "--",
                        self.activate_command_string(system),
                        prompt,
                        log=log,
                        capture_stderr=True,
                    )
                    if result.returncode != 0 and "(-128)" in (result.stderr or ""):
                        message = "Authentication cancelled; the built system was not applied."
                        self.save("cancelled", message, system=system)
                        self.notify(message)
                        return 0
                    if result.returncode:
                        raise ValueError(
                            "System activation failed and may be partial. Inspect the log and current system."
                        )
                    if self.current_system.resolve() != Path(system):
                        raise ValueError(
                            "System activation returned success but did not select the built system; activation is partial. Inspect the log and current system."
                        )
                    message = "System rebuilt and activated. Git changes remain uncommitted."
                    self.save("done", message, system=system)
                    self.notify(message)
                    return 0
                except (OSError, ValueError, subprocess.SubprocessError) as exc:
                    message = str(exc)
                    log.write("\nERROR: " + message + "\n")
                    self.save("failed", message)
                    self.notify(message, error=True)
                    return 1

    def show_log(self):
        if not self.log_file.exists():
            print("No rebuild log yet.", file=sys.stderr)
            return 0
        sys.stdout.write(self.log_file.read_text(errors="replace"))
        return 0


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("action", choices=("status", "start", "run", "log"))
    parser.add_argument("--ready-fd", type=int, default=None)
    args = parser.parse_args()
    try:
        rebuilder = DarwinRebuilder(json.loads(Path(args.config).read_text()), args.config)
        if args.action == "status":
            print(json.dumps(rebuilder.status()))
        elif args.action == "start":
            print(json.dumps(rebuilder.start()))
        elif args.action == "run":
            return rebuilder.run(ready_fd=args.ready_fd)
        else:
            return rebuilder.show_log()
        return 0
    except BlockingIOError:
        print(json.dumps({"started": False, "busy": True}))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
