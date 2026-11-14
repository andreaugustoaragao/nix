"""Apply Nix-owned GTK theme preferences before Chromium acquires its profile."""

import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile


def overlay(current, desired):
    for key, value in desired.items():
        if isinstance(value, dict):
            if not isinstance(current.get(key), dict):
                current[key] = {}
            overlay(current[key], value)
        else:
            current[key] = value


def merge(path, desired):
    current = json.loads(path.read_text()) if path.exists() else {}
    before = json.dumps(current, sort_keys=True)
    overlay(current, desired)
    if path.exists() and json.dumps(current, sort_keys=True) == before:
        return
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".nix-theme-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(current, handle)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def flag(arguments, name, default):
    value = default
    for index, argument in enumerate(arguments):
        if argument == "--":
            break
        if argument.startswith(name + "="):
            value = argument[len(name) + 1:]
        elif argument == name:
            value = arguments[index + 1]
    return value


def prepare(policy, arguments):
    config = Path(os.environ.get("CHROME_CONFIG_HOME") or os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    root = Path(flag(arguments, "--user-data-dir", os.environ.get("CHROME_USER_DATA_DIR") or config / policy["directory"]))
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (root / ".nix-system-theme.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Chromium owns Preferences while running. Even a stale singleton is
        # left for Chromium to recover; the next clean launch reconciles it.
        if os.path.lexists(root / "SingletonLock"):
            return
        local_state = root / "Local State"
        state = json.loads(local_state.read_text()) if local_state.exists() else {}
        profile = flag(arguments, "--profile-directory", state.get("profile", {}).get("last_used", "Default"))
        if not profile or Path(profile).name != profile or profile in (".", ".."):
            raise ValueError("Expected a profile directory name")
        paths = set(root.glob("*/Preferences")) | {root / profile / "Preferences"}
        for path in sorted(paths):
            if path.parent.name != "System Profile":
                merge(path, policy["preferences"])


if __name__ == "__main__":
    prepare(json.loads(Path(sys.argv[1]).read_text()), sys.argv[2:])
