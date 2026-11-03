"""Merge Nix-owned agent settings into writable JSON without losing other hooks."""

import argparse
import copy
import json
import os
from pathlib import Path
import tempfile


def load(path):
    if not path.exists() and not path.is_symlink():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path}")
    return value


def validate(value, kind):
    hooks = value.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks must be an object")
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            raise ValueError(f"hooks.{event} must be an array")
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError(f"hooks.{event} entries must be objects")
            handlers = entry.get("hooks") if kind == "claude" else [entry]
            if not isinstance(handlers, list) or not all(
                isinstance(handler, dict) for handler in handlers
            ):
                raise ValueError(f"hooks.{event} handlers must be an array of objects")


def write(path, value):
    if path.exists() and not path.is_symlink() and load(path) == value:
        path.chmod(0o600)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(json.dumps(value, indent=2) + "\n")
            output.flush()
            os.fsync(output.fileno())
        # Replace the directory entry, never the symlink's store target.
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def strip_settings(current, owned):
    for key, value in owned.items():
        if key not in current:
            continue
        if isinstance(value, dict) and isinstance(current[key], dict):
            strip_settings(current[key], value)
            if not current[key]:
                del current[key]
        elif current[key] == value:
            del current[key]


def overlay(current, desired):
    for key, value in desired.items():
        if isinstance(value, dict) and isinstance(current.get(key), dict):
            overlay(current[key], value)
        else:
            current[key] = copy.deepcopy(value)


def strip_hooks(current, owned, kind):
    for event, entries in owned.items():
        handlers = (
            [handler for entry in entries for handler in entry["hooks"]]
            if kind == "claude" else entries
        )

        def managed(handler):
            # Commands are identities within an event, even if an editor has
            # regrouped Claude matchers or changed a timeout on our handler.
            return any(
                handler.get("command") == old["command"]
                if "command" in old else handler == old
                for old in handlers
            )

        remaining = []
        for entry in current.get(event, []):
            if kind == "claude":
                kept = [handler for handler in entry["hooks"] if not managed(handler)]
                if kept or not entry["hooks"]:
                    remaining.append({**entry, "hooks": kept})
            elif not managed(entry):
                remaining.append(entry)
        if remaining:
            current[event] = remaining
        else:
            current.pop(event, None)


def merge(current, previous, desired, kind):
    result = copy.deepcopy(current)
    hooks = result.pop("hooks", {})
    for owned in previous:
        strip_settings(result, {key: value for key, value in owned.items() if key != "hooks"})
        strip_hooks(hooks, owned.get("hooks", {}), kind)
    # Also recognize the desired commands after a partially completed run.
    strip_hooks(hooks, desired.get("hooks", {}), kind)
    overlay(result, {key: value for key, value in desired.items() if key != "hooks"})
    for event, entries in desired.get("hooks", {}).items():
        hooks[event] = copy.deepcopy(entries) + hooks.get(event, [])
    if hooks or "hooks" in desired:
        result["hooks"] = hooks
    return result


def configure(args):
    current = load(args.target)
    desired = load(args.desired)
    if not args.desired.is_file():
        raise ValueError(f"Missing desired configuration: {args.desired}")
    if args.state.exists() or args.state.is_symlink():
        previous = load(args.state).get("managed")
        if not isinstance(previous, list) or not all(isinstance(item, dict) for item in previous):
            raise ValueError(f"Invalid ownership manifest: {args.state}")
    else:
        # The old generation contains only Nix-owned values, unlike the live
        # file, which may already contain Orca hooks and user preferences.
        previous = [load(args.legacy)] if args.legacy else []
    for value in [current, desired, *previous]:
        validate(value, args.kind)
    result = merge(current, previous, desired, args.kind)
    if args.prepare:
        # Home Manager's linkGeneration would otherwise delete the old link.
        # Validate everything first, then retain its parsed contents locally.
        # Save ownership before it advances the generation pointer as well.
        write(args.state, {"managed": previous})
        if args.target.is_symlink():
            write(args.target, current)
        return
    pending = list(previous)
    if desired not in pending:
        pending.append(desired)
    # Journal both command sets before replacing the config. An interrupted
    # update can then retire either set, even when the next generation changes.
    write(args.state, {"managed": pending})
    write(args.target, result)
    write(args.state, {"managed": [desired]})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=["claude", "cursor"], required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--desired", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--legacy", type=Path)
    parser.add_argument("--prepare", action="store_true")
    try:
        configure(parser.parse_args())
    except (OSError, ValueError) as error:
        parser.exit(1, f"agent-json-configure: {error}\n")
