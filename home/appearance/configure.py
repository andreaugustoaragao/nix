"""Apply Nix-owned appearance fields without replacing unrelated app settings."""

import argparse
import base64
import configparser
import json
import os
from pathlib import Path
import tempfile

import json5
import tomlkit


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and not path.is_symlink() and path.read_text() == content:
        return
    descriptor, temporary = tempfile.mkstemp(prefix=".appearance-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def overlay(current, desired):
    for key, value in desired.items():
        if isinstance(value, dict) and isinstance(current.get(key), dict):
            overlay(current[key], value)
        else:
            current[key] = value


def merge_file(path, entry):
    kind = entry["format"]
    text = path.read_text() if path.exists() else ""
    if kind == "json":
        current = json5.loads(text) if text.strip() else {}
        if not isinstance(current, dict):
            raise ValueError(f"Expected object in {path}")
        overlay(current, entry["set"])
        for key in entry.get("remove", []):
            current.pop(key, None)
        result = json.dumps(current, indent=2) + "\n"
    elif kind == "toml":
        current = tomlkit.parse(text)
        for key, value in entry["set"].items():
            if key not in current or not isinstance(value, dict):
                current[key] = value
            else:
                def merge_table(table, desired):
                    for name, item in desired.items():
                        if isinstance(item, dict) and name in table:
                            merge_table(table[name], item)
                        else:
                            table[name] = item
                merge_table(current[key], value)
        for key in entry.get("remove", []):
            current.pop(key, None)
        result = tomlkit.dumps(current)
    elif kind == "ini":
        current = configparser.ConfigParser(interpolation=None, strict=False)
        current.optionxform = str
        current.read_string(text)
        for section, values in entry["set"].items():
            if not current.has_section(section):
                current.add_section(section)
            for key, value in values.items():
                current.set(section, key, str(value))
        import io
        output = io.StringIO()
        current.write(output, space_around_delimiters=False)
        result = output.getvalue()
    else:
        raise ValueError(f"Unknown appearance document format: {kind}")
    atomic_write(path, result)


def retire_trial(config, state):
    snapshot = state / "gruvbox-trial/snapshot.json"
    if not snapshot.exists():
        return
    data = json.loads(snapshot.read_text())
    pending = []
    for name, record in data["files"].items():
        if name not in ("ghostty/config", "gtk-3.0/gtk.css", "gtk-4.0/gtk.css"):
            raise ValueError(f"Unexpected trial-managed path: {name}")
        path = config / name
        # Nix may have linked a newer generation after an interrupted activation.
        if path.is_symlink() and str(path.resolve()).startswith("/nix/store/"):
            continue
        current = path.read_bytes() if path.exists() else None
        accepted = [base64.b64decode(value["data"]) for value in
                    (record["original"], record["applied"], record.get("previous"))
                    if value and "data" in value]
        if current is not None and current not in accepted:
            raise ValueError(f"Trial file was edited outside the trial; preserve it before rebuilding: {path}")
        pending.append((path, record["original"]))
    for path, original in pending:
        if original is None:
            path.unlink(missing_ok=True)
        elif "link" in original:
            with tempfile.TemporaryDirectory(dir=path.parent, prefix=".appearance-link-") as directory:
                temporary = Path(directory) / "link"
                temporary.symlink_to(original["link"])
                os.replace(temporary, path)
        else:
            atomic_write(path, base64.b64decode(original["data"]).decode())
            path.chmod(original["mode"])
    snapshot.rename(snapshot.with_name("snapshot.migrated.json"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "apply"))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        retire_trial(args.config, args.state)
    else:
        for name, entry in json.loads(args.manifest.read_text()).items():
            target = Path(name.replace("@CONFIG@", str(args.config)).replace("@STATE@", str(args.state)).replace("@HOME@", str(Path.home())))
            merge_file(target, entry)


if __name__ == "__main__":
    main()
