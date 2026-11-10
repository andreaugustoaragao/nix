#!/usr/bin/env python3
"""User-triggered NixOS build, followed by Polkit-authorized activation."""

import argparse
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys

UNIT = "noctalia-nix-rebuild.service"
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


def logged_run(argv, log, capture_stdout=False, **kwargs):
    # Drain both pipes together: Nix's JSON stdout stays untouched while
    # stderr is timestamped, and verbose children cannot deadlock either pipe.
    captured = bytearray()
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs) as process:
        try:
            with selectors.DefaultSelector() as reader:
                for stream in (process.stdout, process.stderr):
                    reader.register(stream, selectors.EVENT_READ, bytearray())
                while reader.get_map():
                    for key, _ in reader.select():
                        data = os.read(key.fd, 65536)
                        if capture_stdout and key.fileobj is process.stdout:
                            captured.extend(data)
                        else:
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
                pass  # pkexec may already have changed to the authorized UID.
            # Drain even if an authorized child cannot be signalled by this user.
            process.communicate()
            raise
        return subprocess.CompletedProcess(argv, process.returncode, captured.decode("utf-8"))


class Rebuilder:
    def __init__(self, config, config_path, state_dir=None):
        self.config = config
        self.config_path = str(config_path)
        self.repository = Path(config["repository"])
        self.state_dir = Path(state_dir or (
            Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
            / "noctalia-nix-rebuild"
        ))
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state_file = self.state_dir / "status.json"
        self.log_file = self.state_dir / "rebuild.log"

    def command(self, name, *args, log=None, capture_stdout=False, **kwargs):
        argv = [self.config[name], *map(str, args)]
        if log is not None:
            return logged_run(argv, log, capture_stdout=capture_stdout, **kwargs)
        return subprocess.run(argv, **kwargs)

    def dirty(self):
        result = self.command(
            "git", "-C", self.repository, "status", "--porcelain=v1", "-z",
            "--untracked-files=normal", capture_output=True, timeout=10,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        )
        if result.returncode:
            raise ValueError("Cannot read the Nix checkout's Git status.")
        return bool(result.stdout)

    def unit_active(self):
        result = self.command(
            "systemctl", "--user", "show", UNIT, "--property=ActiveState", "--value",
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode:
            raise ValueError("Cannot inspect the rebuild job; user systemd is unavailable.")
        return result.stdout.strip() in {"active", "activating", "deactivating", "reloading"}

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
        try:
            self.command(
                "notify", "--app-name=NixOS rebuild", "--icon=system-software-update",
                "--urgency=critical" if error else "--urgency=normal",
                "NixOS rebuild", message, capture_output=True, timeout=10,
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
            busy = self.unit_active()
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            # Do not offer a new build when ownership of an existing job is unknown.
            busy, error = True, error or str(exc)
        if busy and state.get("phase") not in RUNNING:
            state = {"phase": "starting", "message": "Rebuild job is starting or finishing."}
        elif not busy and state.get("phase") in RUNNING:
            state = {"phase": "interrupted", "message": "Rebuild job stopped; inspect the log before retrying."}
        return {
            **state, "dirty": dirty, "busy": busy, "error": error,
            "repository": str(self.repository), "log": str(self.log_file),
        }

    def start(self):
        # Serialize launches from multiple bars/clicks; systemd also enforces one unit.
        with (self.state_dir / "launch.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if self.unit_active():
                return {"started": False, "busy": True}
            if not self.dirty():
                return {"started": False, "busy": False, "message": "Nix checkout is clean."}
            result = self.command(
                "systemd_run", "--user", "--unit=" + UNIT, "--collect", "--quiet",
                "--property=Type=exec", "--", sys.executable, str(Path(__file__).resolve()),
                "--config", self.config_path, "run", capture_output=True, text=True, timeout=15,
            )
            if result.returncode:
                raise ValueError("Could not start the rebuild job: " + result.stderr.strip())
            return {"started": True, "busy": True}

    @staticmethod
    def built_system(stdout, hostname):
        try:
            outputs = json.loads(stdout)
            if not isinstance(outputs, list) or len(outputs) != 1:
                raise ValueError
            path = outputs[0]["outputs"]["out"]
            pattern = r"/nix/store/[0-9a-z]{32}-nixos-system-" + re.escape(hostname) + r"-[^/\s]+"
            if not isinstance(path, str) or not re.fullmatch(pattern, path):
                raise ValueError
            return path
        except (ValueError, KeyError, TypeError) as exc:
            raise ValueError("Build did not return exactly one system closure for this host.") from exc

    def run(self):
        if os.geteuid() == 0:
            raise ValueError("Run the build as your normal user, not root.")
        with (self.state_dir / "run.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.log_file.open("w") as stream:
                log = TimestampLog(stream)
                try:
                    if not self.dirty():
                        self.save("idle", "Nix checkout is clean; nothing was started.")
                        return 0
                    self.save("building", "Building the system as your normal user.")
                    log.write("Building the current tracked Nix checkout. Untracked files are NOT staged automatically.\n")
                    log.flush()
                    host = self.config["hostname"]
                    result = self.command(
                        "nix", "build", "--json", "--no-write-lock-file", "--print-build-logs",
                        "--out-link", self.state_dir / "result",
                        str(self.repository) + "#nixosConfigurations." + host + ".config.system.build.toplevel",
                        log=log, capture_stdout=True,
                    )
                    if result.returncode:
                        raise ValueError("System build failed. Right-click the button to read the log.")
                    system = self.built_system(result.stdout, host)
                    self.save("applying", "Authenticate in the GUI to apply the built system.", system=system)
                    log.write("\nApplying the exact built closure: " + system + "\n")
                    log.flush()
                    self.notify("Build ready. Authenticate in the GUI to apply it; cancel to keep the current system.")
                    result = self.command(
                        "pkexec", "--disable-internal-agent", self.config["rebuild"],
                        "switch", "--store-path", system, "--no-reexec",
                        log=log,
                    )
                    if result.returncode == 126:
                        message = "Authentication cancelled; the built system was not applied."
                        self.save("cancelled", message, system=system)
                        self.notify(message)
                        return 0
                    if result.returncode == 127:
                        raise ValueError("GUI authorization failed or no authentication agent is available. Inspect the log.")
                    if result.returncode:
                        raise ValueError("System activation failed and may be partial. Inspect the log and current system.")
                    message = "System rebuilt and activated. Git changes remain uncommitted."
                    self.save("done", message, system=system)
                    self.notify(message)
                    return 0
                except (OSError, ValueError, subprocess.SubprocessError) as exc:
                    message = str(exc)
                    log.write("\nERROR: " + message + "\n")
                    self.save("failed", message)
                    self.notify(message + " Right-click the button to read the log.", error=True)
                    return 1

    def show_log(self):
        if not self.log_file.exists():
            self.notify("No rebuild log yet. Left-click the toolbar button to start a rebuild.")
            return 0
        return self.command(
            # The native viewer only reads files; closing it cannot cancel
            # the separate systemd rebuild job. Paths are literal argv entries.
            "log_viewer", "--log", self.log_file, "--status", self.state_file,
        ).returncode


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("action", choices=("status", "start", "run", "log"))
    args = parser.parse_args()
    try:
        rebuilder = Rebuilder(json.loads(Path(args.config).read_text()), args.config)
        if args.action == "status":
            print(json.dumps(rebuilder.status()))
        elif args.action == "start":
            print(json.dumps(rebuilder.start()))
        elif args.action == "run":
            return rebuilder.run()
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
