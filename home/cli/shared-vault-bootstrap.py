#!/usr/bin/env python3
"""Import pinned private release inputs and build the immutable Nix runtime."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ARCHIVE_NAME = "shared-vault-release.tar.gz"
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_SOURCE_BYTES = 64 * 1024 * 1024
DESKTOP_SOURCE_NAME = "fulcrum-desktop-source"


class RestoreError(Exception):
    pass


class AssetRedirect(urllib.request.HTTPRedirectHandler):
    allowed_hosts = {"api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}

    def redirect_request(self, request, response, code, message, headers, url):
        target = urllib.parse.urlsplit(url)
        if target.scheme != "https" or target.hostname not in self.allowed_hosts or target.username or target.password:
            raise RestoreError("Unexpected release download redirect")
        redirected = super().redirect_request(request, response, code, message, headers, url)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


def read_pin(path):
    pin = json.loads(path.read_text())
    if set(pin) != {"url", "hash", "packageVersion", "sourceRevision"}:
        raise RestoreError("Unexpected release pin fields")
    if not re.fullmatch(r"[a-f0-9]{40}", pin["sourceRevision"]):
        raise RestoreError("Release pin needs a full source commit")
    if not re.fullmatch(r"\d+\.\d+\.\d+", pin["packageVersion"]):
        raise RestoreError("Invalid package version")
    if not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", pin["hash"]):
        raise RestoreError("Release pin needs a SHA256 SRI digest")
    if pin["url"] is not None and not re.fullmatch(r"https://github\.com/andrearagao/fulcrum/releases/download/[A-Za-z0-9._-]+/shared-vault-release\.tar\.gz", pin["url"]):
        raise RestoreError("Release URL must name the private Fulcrum release asset")
    return pin


def checked_token(value):
    if not value or not re.fullmatch(r"[\x21-\x7e]+", value):
        raise RestoreError("Invalid GitHub credential format; provide a single token without whitespace")
    return value


def github_token():
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return checked_token(token)
    result = subprocess.run(
        ["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
        text=True, capture_output=True, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}, timeout=30,
    )
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if result.returncode or not fields.get("password"):
        raise RestoreError("A GitHub credential with read access to andrearagao/fulcrum is required")
    return checked_token(fields["password"])


def download(pin, destination):
    if pin["url"] is None:
        raise RestoreError("This release is local-only; provide --archive PATH to the retained certified archive")
    tag = urllib.parse.urlsplit(pin["url"]).path.split("/")[-2]
    headers = {
        "Authorization": "Bearer " + github_token(), "Accept": "application/vnd.github+json",
        "User-Agent": "shared-vault-bootstrap", "X-GitHub-Api-Version": "2022-11-28",
    }
    opener = urllib.request.build_opener(AssetRedirect())
    request = urllib.request.Request("https://api.github.com/repos/andrearagao/fulcrum/releases/tags/" + tag, headers=headers)
    with opener.open(request, timeout=60) as response:
        metadata = response.read(1024 * 1024 + 1)
    if len(metadata) > 1024 * 1024:
        raise RestoreError("Release metadata exceeds its bound")
    release = json.loads(metadata)
    assets = [asset for asset in release["assets"] if asset["name"] == ARCHIVE_NAME]
    if len(assets) != 1 or type(assets[0]["id"]) is not int or not 0 < assets[0]["size"] <= MAX_ARCHIVE_BYTES:
        raise RestoreError("Release must contain exactly one bounded runtime archive")
    asset = assets[0]
    request = urllib.request.Request(
        "https://api.github.com/repos/andrearagao/fulcrum/releases/assets/" + str(asset["id"]),
        headers={**headers, "Accept": "application/octet-stream"},
    )
    with opener.open(request, timeout=120) as response, destination.open("xb") as output:
        size = 0
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > asset["size"]:
                raise RestoreError("Release download exceeds the declared size")
            output.write(chunk)
    if size != asset["size"]:
        raise RestoreError("Release download is incomplete")


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.digest()


def import_archive(pin, archive):
    if "sha256-" + base64.b64encode(file_digest(archive)).decode() != pin["hash"]:
        raise RestoreError("Archive SHA256 does not match the committed pin; nothing was imported")
    result = subprocess.run(["nix-store", "--add-fixed", "sha256", str(archive)], check=True, capture_output=True, text=True)
    return result.stdout.strip()


class SourceRedirect(AssetRedirect):
    allowed_hosts = {"api.github.com", "codeload.github.com"}


def read_desktop_pin(path):
    pin = json.loads(path.read_text())
    if (not isinstance(pin, dict) or set(pin) != {"revision", "hash"}
            or not isinstance(pin["revision"], str) or not re.fullmatch(r"[a-f0-9]{40}", pin["revision"])):
        raise RestoreError("Desktop source pin requires its full revision and unpacked hash")
    if not isinstance(pin["hash"], str) or not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", pin["hash"]):
        raise RestoreError("Desktop source pin needs a SHA256 SRI digest")
    return pin


def download_desktop(pin, destination):
    request = urllib.request.Request(
        "https://api.github.com/repos/andrearagao/fulcrum/tarball/" + pin["revision"],
        headers={"Authorization": "Bearer " + github_token(), "Accept": "application/vnd.github+json",
                 "User-Agent": "shared-vault-bootstrap", "X-GitHub-Api-Version": "2022-11-28"},
    )
    opener = urllib.request.build_opener(SourceRedirect())
    with opener.open(request, timeout=120) as response, destination.open("xb") as output:
        size = 0
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_SOURCE_BYTES:
                raise RestoreError("Desktop source archive exceeds its bound")
            output.write(chunk)


def import_desktop_archive(pin, archive):
    if archive.stat().st_size > MAX_SOURCE_BYTES:
        raise RestoreError("Desktop source archive exceeds its bound")
    result = subprocess.run(
        ["nix-prefetch-url", "--unpack", "--name", DESKTOP_SOURCE_NAME, "--print-path",
         archive.resolve().as_uri(), pin["hash"]],
        check=True, capture_output=True, text=True,
    )
    lines = result.stdout.splitlines()
    if len(lines) != 2 or not lines[1].startswith("/nix/store/"):
        raise RestoreError("Expected one imported desktop source store path")
    return lines[1]


def verify_package(package, pin):
    root = package / "share/vault-services"
    manifest = json.loads((root / "release.json").read_text())
    expected = {"packageVersion": pin["packageVersion"], "source": {"kind": "artifact", "revision": pin["sourceRevision"]}}
    if manifest != expected or json.loads((root / "package.json").read_text())["version"] != pin["packageVersion"]:
        raise RestoreError("Nix package identity differs from the release pin")
    return root


def main():
    flake = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", type=Path, default=flake / "home/services/shared-vault-prl-dev-vm-release.json")
    parser.add_argument("--archive", type=Path, help="Use a retained archive instead of downloading")
    parser.add_argument("--archive-only", action="store_true", help="Import only the verified runtime archive, without building the package")
    parser.add_argument("--desktop-archive", type=Path, help="Use a retained desktop source archive instead of downloading")
    args = parser.parse_args()
    pin = read_pin(args.pin)
    with tempfile.TemporaryDirectory(prefix="shared-vault-bootstrap-") as scratch:
        archive = Path(scratch) / ARCHIVE_NAME
        if args.archive:
            shutil.copyfile(args.archive, archive)
        else:
            download(pin, archive)
        imported = import_archive(pin, archive)
        print("Verified archive imported: " + imported, file=sys.stderr, flush=True)
    result = {"archive": imported, "hash": pin["hash"], "sourceRevision": pin["sourceRevision"]}
    if not args.archive_only:
        desktop = read_desktop_pin(flake / "home/desktop/fulcrum-source.json")
        with tempfile.TemporaryDirectory(prefix="fulcrum-desktop-source-") as scratch:
            source_archive = Path(scratch) / "source.tar.gz"
            if args.desktop_archive:
                shutil.copyfile(args.desktop_archive, source_archive)
            else:
                download_desktop(desktop, source_archive)
            result["desktopSource"] = import_desktop_archive(desktop, source_archive)
        result["desktopSourceRevision"] = desktop["revision"]
        attribute = "#nixosConfigurations.prl-dev-vm.config.home-manager.users.aragao.my.sharedVault.release"
        build = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", str(flake) + attribute], check=True, stdout=subprocess.PIPE, text=True)
        paths = build.stdout.splitlines()
        if len(paths) != 1:
            raise RestoreError("Expected one Nix runtime package")
        package = Path(paths[0])
        result["package"] = str(package)
        result["applicationRoot"] = str(verify_package(package, pin))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except subprocess.SubprocessError:
        raise SystemExit("Restore failed: a required command failed; review its diagnostic output") from None
    except ValueError:
        raise SystemExit("Restore failed: invalid release metadata or configuration") from None
    except (RestoreError, OSError) as error:
        raise SystemExit("Restore failed: " + str(error)) from None
