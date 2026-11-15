#!/usr/bin/env python3
"""Pin a published desktop release after verifying both native archives."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import tempfile
from urllib.request import Request, urlopen


def download(url):
    return urlopen(Request(url, headers={"User-Agent": "nix-desktop-release-update"}), timeout=120)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", choices=("folio", "vereda", "vitals"))
    parser.add_argument("version")
    args = parser.parse_args()
    base = f"https://github.com/andrearagao/desktop-releases/releases/download/{args.application}-v{args.version}"
    with download(base + "/release.json") as response:
        manifests = json.load(response)
    with download(base + "/SHA256SUMS") as response:
        sums = dict(reversed(line.split()) for line in response.read().decode().splitlines())
    release = {"version": args.version, "sourceRevision": None, "hashes": {}}
    for system in ("aarch64-linux", "x86_64-linux"):
        manifest, = [item for item in manifests if item["system"] == system]
        if manifest["application"] != args.application or manifest["version"] != args.version:
            raise ValueError(f"release manifest does not match {args.application} {args.version}")
        revision = manifest["sourceRevision"]
        if release["sourceRevision"] not in (None, revision):
            raise ValueError("architectures have different source revisions")
        release["sourceRevision"] = revision
        filename = f"{args.application}-{args.version}-{system}.tar.gz"
        digest = hashlib.sha256()
        with download(base + "/" + filename) as response:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
        if digest.hexdigest() != sums[filename]:
            raise ValueError(f"checksum mismatch for {filename}")
        release["hashes"][system] = "sha256-" + base64.b64encode(digest.digest()).decode()
    path = Path(__file__).resolve().parents[1] / "pkgs/desktop-releases.json"
    pins = json.loads(path.read_text())
    pins[args.application] = release
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        json.dump(pins, output, indent=2)
        output.write("\n")
        temporary = Path(output.name)
    temporary.chmod(0o644)
    temporary.replace(path)
    print(f"Pinned {args.application} {args.version} at {release['sourceRevision']}")


if __name__ == "__main__":
    main()
