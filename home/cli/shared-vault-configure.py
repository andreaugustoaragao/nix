"""Own only the shared-vault MCP entry; never emit surrounding configuration."""

import argparse
import copy
import fcntl
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile

import json5
import tomlkit


class Conflict(Exception):
    pass


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Conflict("duplicate-key")
        result[key] = value
    return result


def json_number(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("nonfinite-number")
    return number


def parse(text, kind):
    try:
        if not text:
            return tomlkit.document() if kind == "codex" else {}
        if kind == "codex":
            result = tomlkit.parse(text)
        elif kind == "opencode":
            result = json5.loads(text, allow_duplicate_keys=False, parse_float=json_number, parse_constant=json_number)
        else:
            result = json.loads(text, object_pairs_hook=object_pairs, parse_float=json_number, parse_constant=json_number)
        if not isinstance(result, dict):
            raise Conflict("invalid-object")
        return result
    except (ValueError, TypeError, RecursionError, tomlkit.exceptions.TOMLKitError) as error:
        raise Conflict("invalid-configuration") from error


def snapshot(path, generated=False):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | (0 if generated else os.O_NOFOLLOW))
    except FileNotFoundError:
        if path.is_symlink():
            raise Conflict("unsafe-file") from None
        return None
    except OSError as error:
        raise Conflict("unreadable-or-unsafe-file") from error
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024
                or (not generated and (info.st_uid != os.getuid() or info.st_nlink != 1))):
            raise Conflict("unsafe-file")
        content = source.read(4 * 1024 * 1024 + 1)
        if len(content) > 4 * 1024 * 1024:
            raise Conflict("oversized-file")
        return ((info.st_dev, info.st_ino, info.st_mtime_ns, info.st_mode), content)


def decode(saved, kind):
    try:
        return parse(saved[1].decode("utf-8"), kind) if saved else parse("", kind)
    except UnicodeError as error:
        raise Conflict("invalid-encoding") from error


def same(left, right):
    try:
        return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        return False


def entry(document, kind, name):
    keys = ["mcp_servers"] if kind == "codex" else ["mcp", "servers"] if kind == "opencode" else ["mcpServers"]
    value = document
    for key in keys:
        value = value.get(key, {})
        if not isinstance(value, dict):
            raise Conflict("invalid-server-map")
    if name in value and not isinstance(value[name], dict):
        raise Conflict("invalid-server-entry")
    return value.get(name)


def render(document, kind, name, desired):
    try:
        result = copy.deepcopy(document)
        key = "mcp_servers" if kind == "codex" else "mcpServers"
        if desired is not None:
            if key not in result:
                result[key] = {}
            result[key][name] = copy.deepcopy(desired)
        elif key in result:
            result[key].pop(name, None)
        return (tomlkit.dumps(result) if kind == "codex" else json.dumps(result, indent=2, allow_nan=False) + "\n").encode()
    except (ValueError, TypeError, RecursionError, tomlkit.exceptions.TOMLKitError) as error:
        raise Conflict("invalid-configuration") from error


def sync_directory_chain(path):
    path = path.resolve(strict=True)
    device = path.stat().st_dev
    while True:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            if os.fstat(descriptor).st_dev != device:
                return
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        if path.parent == path:
            return
        path = path.parent


def private_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Conflict("unsafe-state-directory")
    # Existing ancestors may come from an interrupted, unflushed attempt.
    sync_directory_chain(path)


def sync_configuration(path, expected, generated=False):
    if snapshot(path, generated) != expected:
        raise Conflict("changed-during-update")
    if expected is not None and not (generated and path.is_symlink()):
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(descriptor)
            if (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_mode) != expected[0]:
                raise Conflict("changed-during-update")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    parent = path.parent
    while not parent.exists():
        if parent.is_symlink():
            raise Conflict("unsafe-file")
        parent = parent.parent
    sync_directory_chain(parent)
    if snapshot(path, generated) != expected:
        raise Conflict("changed-during-update")


def atomic_write(path, content, expected):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    sync_directory_chain(path.parent)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        if snapshot(path) != expected:
            raise Conflict("changed-during-update")
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def journal(path, value, expected):
    atomic_write(path, (json.dumps(value, indent=2) + "\n").encode(), expected)
    return snapshot(path)


def ownership(saved, client, name):
    if saved is None:
        return None
    value = decode(saved, "json")
    if (set(value) != {"version", "client", "target", "name", "managed"}
            or type(value["version"]) is not int or value["version"] != 1
            or value["client"] != client["kind"] or value["target"] != client["target"]
            or value["name"] != name or not isinstance(value["managed"], list)
            or not 1 <= len(value["managed"]) <= 2
            or any(item is not None and not isinstance(item, dict) for item in value["managed"])):
        raise Conflict("invalid-ownership-journal")
    return value


def activation(state_directory):
    saved = snapshot(state_directory / "activation.json")
    if saved is None:
        return {"version": 1, "phase": "settled", "generated": []}, None
    value = decode(saved, "json")
    if (set(value) != {"version", "phase", "generated"} or type(value["version"]) is not int
            or value["version"] != 1 or not isinstance(value["generated"], list)
            or value["phase"] not in ("prepared", "settled")
            or len(value["generated"]) > 1):
        raise Conflict("invalid-activation-receipt")
    for item in value["generated"]:
        if (not isinstance(item, dict) or set(item) != {"target", "sources"}
                or not isinstance(item["target"], str) or not Path(item["target"]).is_absolute()
                or not isinstance(item["sources"], list) or len(item["sources"]) > 2
                or any(not isinstance(source, str) or not Path(source).is_absolute() for source in item["sources"])):
            raise Conflict("invalid-activation-receipt")
    return value, saved


def generated_source(client, state_directory):
    previous, _ = activation(state_directory)
    accepted = []
    for item in previous["generated"]:
        if item["target"] != client["target"]:
            raise Conflict("generated-target-changed")
        accepted.extend(item["sources"])
    if client["generated"] is not None:
        accepted.append(str(Path(client["generated"]).resolve(strict=True)))
    target = Path(client["target"])
    if not target.is_symlink() or str(target.resolve(strict=True)) not in accepted:
        raise Conflict("unowned-generated-registration")
    return str(target.resolve(strict=True))


def record_activation(desired, state_directory, mode):
    previous, saved = activation(state_directory)
    value = copy.deepcopy(previous)
    value["phase"] = "prepared" if mode == "prepare" else "settled"
    for client in desired["clients"]:
        if client["kind"] != "opencode":
            continue
        if any(item["target"] != client["target"] for item in previous["generated"]):
            raise Conflict("generated-target-changed")
        target = Path(client["target"])
        published = snapshot(target, generated=True)
        sources = []
        if mode == "prepare":
            current = entry(decode(published, "opencode"), "opencode", desired["name"])
            if current is not None:
                sources.append(generated_source(client, state_directory))
        if client["desired"] is not None:
            sources.append(str(Path(client["generated"]).resolve(strict=True)))
        sync_configuration(target, published, generated=True)
        value["generated"] = [{"target": client["target"], "sources": list(dict.fromkeys(sources))}]
    if saved is None or not same(previous, value):
        journal(state_directory / "activation.json", value, saved)


def reconcile(client, name, state_directory, mode="check"):
    kind, desired = client["kind"], client["desired"]
    target = Path(client["target"])
    saved = snapshot(target, generated=kind == "opencode")
    document = decode(saved, kind)
    current = entry(document, kind, name)
    if kind == "opencode":
        # The declarative JSONC file belongs to opencode.nix, never this writer.
        if name in document.get("mcp", {}):
            raise Conflict("legacy-registration-conflict")
        if current is not None:
            generated_source(client, state_directory)
        if mode != "prepare" and not same(current, desired):
            raise Conflict("generated-registration-drift")
        overlay = Path(client["overlay"])
        overlay_document = decode(snapshot(overlay, generated=True), kind)
        overlay_entry = entry(overlay_document, kind, name)
        if name in overlay_document.get("mcp", {}):
            raise Conflict("legacy-registration-conflict")
        if overlay_entry is not None and not same(overlay_entry, desired):
            raise Conflict("overlay-registration-drift")
        if mode == "prepare":
            return "ready"
        return "configured" if desired is not None else "absent"
    state_path = state_directory / f"{kind}.json"
    state_saved = snapshot(state_path)
    previous = ownership(state_saved, client, name)
    if current is not None and (previous is None or not any(same(current, old) for old in previous["managed"])):
        raise Conflict("unowned-or-modified-registration")
    if mode == "prepare":
        return "ready"
    settled = previous is not None and same(previous["managed"], [desired])
    if same(current, desired) and (settled or (desired is None and previous is None)):
        return "configured" if desired is not None else "absent"
    if mode != "apply":
        raise Conflict("registration-drift")
    # Visible publication may precede a failed flush; keep old ownership until durable.
    sync_configuration(target, saved)
    pending = {"version": 1, "client": kind, "target": str(target), "name": name,
               "managed": [current] if same(current, desired) else [current, desired]}
    state_saved = journal(state_path, pending, state_saved)
    if not same(current, desired):
        atomic_write(target, render(document, kind, name, desired), saved)
    journal(state_path, {**pending, "managed": [desired]}, state_saved)
    return "configured" if desired is not None else "retired"


def manifest(path):
    value = decode(snapshot(path, generated=True), "json")
    if (set(value) != {"version", "name", "clients"} or type(value["version"]) is not int
            or value["version"] != 1 or value["name"] != "shared-vault"
            or not isinstance(value["clients"], list)):
        raise Conflict("invalid-manifest")
    seen = set()
    targets = set()
    for client in value["clients"]:
        if not isinstance(client, dict):
            raise Conflict("invalid-manifest-client")
        kind = client.get("kind")
        fields = {"kind", "target", "desired", "overlay", "generated"} if kind == "opencode" else {"kind", "target", "desired"}
        if (kind not in {"codex", "claude", "cursor", "pi", "opencode"} or kind in seen
                or set(client) != fields or not isinstance(client["target"], str)
                or not Path(client["target"]).is_absolute() or client["target"] in targets
                or (client["desired"] is not None and not isinstance(client["desired"], dict))
                or (kind == "opencode" and (not isinstance(client["overlay"], str)
                                           or not Path(client["overlay"]).is_absolute()
                                           or (client["generated"] is not None and (not isinstance(client["generated"], str)
                                                                                   or not Path(client["generated"]).is_absolute()))
                                           or (client["desired"] is not None and client["generated"] is None)))):
            raise Conflict("invalid-manifest-client")
        seen.add(kind)
        targets.add(client["target"])
    return value


def run(args):
    desired = manifest(args.manifest)
    mode = "apply" if args.apply else "prepare" if args.prepare else "check"
    lock = None
    try:
        if mode != "check":
            private_directory(args.state_directory)
            descriptor = os.open(args.state_directory / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            lock = os.fdopen(descriptor, "r+")
            info = os.fstat(lock.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                raise Conflict("unsafe-lock")
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        activation(args.state_directory)
        results = []
        for client in desired["clients"]:
            try:
                status = reconcile(client, desired["name"], args.state_directory, mode)
                results.append({"client": client["kind"], "status": status, "ok": True})
            except (Conflict, OSError) as error:
                results.append({"client": client["kind"], "status": str(error) if isinstance(error, Conflict) else "filesystem-error", "ok": False})
        if mode != "check" and all(item["ok"] for item in results):
            record_activation(desired, args.state_directory, mode)
        receipt, saved = activation(args.state_directory)
        receipt_ready = saved is not None and receipt["phase"] == "settled"
        if saved is None and all(client["desired"] is None for client in desired["clients"]):
            receipt_ready = True
        print(json.dumps({"version": 1, "mode": mode, "activation": receipt["phase"] if saved else "unmanaged", "clients": results}))
        return 0 if all(item["ok"] for item in results) and (mode != "check" or receipt_ready) else 2
    finally:
        if lock is not None:
            lock.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--state-directory", type=Path, required=True)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--apply", action="store_true")
    modes.add_argument("--prepare", action="store_true")
    modes.add_argument("--check", action="store_true")
    try:
        sys.exit(run(parser.parse_args()))
    except (Conflict, OSError) as error:
        parser.exit(2, "shared-vault-configure: " + (str(error) if isinstance(error, Conflict) else "filesystem-error") + "\n")
