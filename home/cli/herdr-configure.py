"""Reconcile Herdr registrations without replacing agent-owned preferences."""

import argparse
import copy
import json
import os
from pathlib import Path
import shlex
import tempfile

import json5


def load(path):
    if not path.exists():
        return {}
    parser = json5 if path.suffix == ".jsonc" else json
    value = parser.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Expected an object in {path}")
    return value


def write(path, value):
    if path.exists() and load(path) == value:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(json.dumps(value, indent=2) + "\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def codex_hooks(value, script):
    result = copy.deepcopy(value)
    hooks = result.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Codex hooks must be an object")
    # Retire previous Herdr lifecycle registrations, preserving other handlers
    # even when they share a matcher group with an old Herdr handler.
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"Codex {event} hooks must be an array")
        remaining = []
        for group in groups:
            handlers = group["hooks"]
            kept = []
            for handler in handlers:
                command = handler.get("command", "")
                if str(script) not in shlex.split(command):
                    kept.append(handler)
            if kept:
                remaining.append({**group, "hooks": kept})
        hooks[event] = remaining
    hooks.setdefault("SessionStart", []).append({"hooks": [{
        "type": "command", "command": f"bash {shlex.quote(str(script))} session", "timeout": 10,
    }]})
    return result


def plugin_config(value, key, plugin):
    result = copy.deepcopy(value)
    plugins = result.setdefault(key, [])
    if not isinstance(plugins, list):
        raise ValueError(f"OpenCode {key} must be an array")
    if not any(entry == plugin or (isinstance(entry, list) and entry[:1] == [plugin])
               for entry in plugins):
        plugins.append(plugin)
    return result


def configure(home, config_home, state_home):
    codex = home / ".codex/hooks.json"
    write(codex, codex_hooks(load(codex), home / ".codex/herdr-agent-state.sh"))
    opencode = config_home / "opencode"
    # Match Herdr's V1 registration while allowing JSONC and existing plugins.
    tui = opencode / "tui.json"
    if not tui.exists():
        tui = opencode / "tui.jsonc"
    write(tui, plugin_config(load(tui), "plugin", "./herdr-tui-session.js"))
    cli = opencode / "cli.json"
    # Let OpenCode import old TUI preferences before creating its V2 config.
    if not cli.exists() and ((opencode / "tui.json").exists()
                             or (state_home / "opencode/kv.json").exists()):
        print("Herdr: OpenCode V2 preference migration pending; start opencode2, then rebuild.")
        return
    write(cli, plugin_config(load(cli), "plugins", "./herdr-opencode"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--config-home", type=Path, required=True)
    parser.add_argument("--state-home", type=Path, required=True)
    args = parser.parse_args()
    configure(args.home, args.config_home, args.state_home)
