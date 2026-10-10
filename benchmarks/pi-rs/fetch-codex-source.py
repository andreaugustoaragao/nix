#!/usr/bin/env python3
"""Download the immutable public source used by the command benchmark."""
import argparse
import hashlib
from pathlib import Path
import urllib.request

COMMIT = "c1382380de69521303b416720a52f42d51af6248"
FILES = {
    "codex-rs/utils/string/src/truncate.rs": "2f00b33069af787f3d208ba8b9b5a8431309ea7b499a7a2d437ce93890c99333",
    "codex-rs/utils/output-truncation/src/lib.rs": "86853aa4f4e73359de296c37c1cad5b0a71168d64d4b0b9f37e329cc0a402b2c",
    "codex-rs/core/src/unified_exec/mod.rs": "8c8d7dfad1d75e8f68725c8f96851cb93e581f796574f1f1ec65509927d86e25",
    "codex-rs/core/src/tools/context.rs": "9a9acc6daab2112bd9ca1a07a1e1f2105b20a7f565878157c726ee0d7a3e00cc",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    for name, expected in FILES.items():
        target = args.destination / name.replace("/", "_")
        data = target.read_bytes() if target.exists() else urllib.request.urlopen(
            f"https://raw.githubusercontent.com/openai/codex/{COMMIT}/{name}", timeout=30
        ).read()
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Source hash mismatch: {name}: {actual}")
        target.write_bytes(data)
        print(f"Verified {name}")


if __name__ == "__main__":
    main()
