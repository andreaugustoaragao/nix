#!/usr/bin/env python3
"""Apply the declared Herdr layout without replacing unrelated app state."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def write_json_atomic(path: Path, payload: dict) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def reconcile_programs(root: Path, programs_path: Path) -> None:
    desired = json.loads(programs_path.read_text())
    if not isinstance(desired, dict) or not isinstance(desired.get("programs"), dict):
        raise ValueError(f"Declared Herdr programs must contain a programs object: {programs_path}")
    root.mkdir(parents=True, exist_ok=True)
    target = root / "programs.json"
    if target.exists():
        current = json.loads(target.read_text())
        if not isinstance(current, dict):
            raise ValueError("Herdr programs.json must contain an object; the original is preserved")
    else:
        current = {}
    merged = dict(current)
    existing_programs = merged.get("programs")
    if existing_programs is None:
        next_programs = {}
    elif isinstance(existing_programs, dict):
        next_programs = dict(existing_programs)
    else:
        raise ValueError("Herdr programs.json 'programs' must be an object; the original is preserved")
    for key, entry in desired["programs"].items():
        next_programs[key] = entry
    merged["programs"] = next_programs
    if target.exists() and not target.is_symlink() and current == merged:
        return
    write_json_atomic(target, merged)


def configure(root: Path, layout: str, app: str, programs: Path | None = None) -> None:
    if programs is not None:
        reconcile_programs(root, programs)
    if not (root / "layouts" / f"{layout}.json").is_file():
        raise ValueError(f"Declared Herdr layout is missing: {layout}")
    root.mkdir(parents=True, exist_ok=True)
    state_file = root / "shared.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    if not isinstance(state, dict):
        raise ValueError("Herdr shared.json must contain an object; the original is preserved")

    environment = dict(os.environ, HERDR_APP_HOME=str(root))
    try:
        running = subprocess.run([app, "status"], env=environment, capture_output=True, text=True)
    except FileNotFoundError:
        running = None
    if running is not None and running.returncode == 0:
        current = json.loads(running.stdout)
        if current.get("layout") != layout:
            subprocess.run(
                [app, "do", "layout.switch", "--name", layout],
                env=environment,
                check=True,
            )
        # The running app owns shared.json and persists the layout itself.
        return

    if state.get("layout") == layout:
        return
    state["layout"] = layout
    write_json_atomic(state_file, state)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--layout", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--programs", type=Path)
    args = parser.parse_args()
    configure(args.root, args.layout, args.app, args.programs)
