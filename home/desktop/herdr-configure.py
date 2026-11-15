#!/usr/bin/env python3
"""Apply the declared Herdr layout without replacing unrelated app state."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def configure(root: Path, layout: str, app: str) -> None:
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
    descriptor, temporary = tempfile.mkstemp(prefix=".shared-", dir=root)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(state, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, state_file)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--layout", required=True)
    parser.add_argument("--app", required=True)
    args = parser.parse_args()
    configure(args.root, args.layout, args.app)
