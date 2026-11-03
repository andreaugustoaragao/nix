"""Overlay Nix's Codex settings while preserving runtime-added configuration."""

import argparse
from collections.abc import MutableMapping
from pathlib import Path

import tomlkit


def overlay(current, desired):
    for key, value in desired.items():
        if isinstance(value, MutableMapping) and isinstance(current.get(key), MutableMapping):
            overlay(current[key], value)
        else:
            current[key] = value


def configure(existing, desired):
    current = tomlkit.parse(existing.read_text()) if existing.exists() else tomlkit.document()
    overlay(current, tomlkit.parse(desired.read_text()))
    desired.write_text(tomlkit.dumps(current))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("existing", type=Path)
    parser.add_argument("desired", type=Path)
    args = parser.parse_args()
    configure(args.existing, args.desired)
