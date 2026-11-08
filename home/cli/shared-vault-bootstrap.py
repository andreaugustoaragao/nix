#!/usr/bin/env python3
"""Restore the pinned prl-dev-vm runtime from Git and a private release asset."""

import argparse
import base64
import ctypes
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


class RestoreError(Exception):
    pass


class AssetRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        target = urllib.parse.urlsplit(url)
        if target.scheme != "https" or target.hostname not in {
            "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"
        } or target.username or target.password:
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
    if not re.fullmatch(r"https://github\.com/andrearagao/fulcrum/releases/download/[A-Za-z0-9._-]+/shared-vault-release\.tar\.gz", pin["url"]):
        raise RestoreError("Release URL must name the private Fulcrum release asset")
    return pin


def github_token():
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token
    result = subprocess.run(
        ["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
        text=True, capture_output=True, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}, timeout=30,
    )
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if result.returncode or not fields.get("password"):
        raise RestoreError("A GitHub credential with read access to andrearagao/fulcrum is required")
    return fields["password"]


def download(pin, destination):
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


def git(root, *args):
    return subprocess.check_output(["git", "--no-replace-objects", "-C", str(root), *args])


def source_repository(value):
    if "://" in value:
        parsed = urllib.parse.urlsplit(value)
        if (parsed.scheme not in {"https", "ssh", "file"} or parsed.password is not None
                or (parsed.scheme == "https" and parsed.username is not None)
                or parsed.query or parsed.fragment):
            raise RestoreError("Source repository must use a local path, SSH, or HTTPS without embedded credentials; use Git's credential helper")
    return value


def publish_checkout(staging, target):
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "linux":
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(-100, os.fsencode(staging), -100, os.fsencode(target), 1)
    elif sys.platform == "darwin":
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(os.fsencode(staging), os.fsencode(target), 4)
    else:
        raise RestoreError("Atomic exclusive checkout publication requires Linux or Darwin")
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(target))


def verify_checkout_layout(root, tracked):
    directories = {parent.as_posix() for name in tracked for parent in Path(name).parents}
    for current, dirs, files in os.walk(root, followlinks=False):
        directory = Path(current)
        for name in dirs[:]:
            path = directory / name
            relative = path.relative_to(root).as_posix()
            if relative == ".git" and not path.is_symlink():
                dirs.remove(name)
            elif relative == "node_modules":
                dirs.remove(name)
            elif relative not in directories or path.is_symlink():
                raise RestoreError("Runtime checkout contains an unexpected directory; it was preserved: " + relative)
        for name in files:
            relative = (directory / name).relative_to(root).as_posix()
            if relative not in tracked and relative != "node_modules":
                raise RestoreError("Runtime checkout contains an unexpected file; it was preserved: " + relative)


def verify_checkout(root, package, pin):
    if git(root, "rev-parse", "HEAD").decode().strip() != pin["sourceRevision"]:
        raise RestoreError("Existing runtime checkout has a different commit")
    if git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise RestoreError("Runtime checkout contains local changes; it was preserved")
    source = package / "share/vault-services"
    tracked = set(git(root, "ls-files", "-z").decode().split("\0")) - {""}
    verify_checkout_layout(root, tracked)
    for name in sorted(tracked):
        local = root / name
        certified = source / name
        if name == ".env.example":
            # The certified archive deliberately omits this tracked template.
            if local.is_symlink() or local.read_bytes() != git(root, "show", pin["sourceRevision"] + ":.env.example"):
                raise RestoreError("Environment template differs from the pinned Git commit")
            continue
        if not certified.is_file() or local.is_symlink() or file_digest(local) != file_digest(certified):
            raise RestoreError("Checkout bytes differ from the pinned package: " + name)
        if bool(local.stat().st_mode & 0o111) != bool(certified.stat().st_mode & 0o111):
            raise RestoreError("Checkout executable mode differs: " + name)
    dependencies = root / "node_modules"
    if not dependencies.is_symlink() or dependencies.resolve() != source / "node_modules":
        raise RestoreError("Runtime dependencies do not point to the pinned Nix package")


def restore_checkout(repository, runtime_root, package, pin):
    repository = source_repository(repository)
    manifest = json.loads((package / "share/vault-services/release.json").read_text())
    expected = {"packageVersion": pin["packageVersion"], "source": {"kind": "artifact", "revision": pin["sourceRevision"]}}
    if manifest != expected:
        raise RestoreError("Nix package identity differs from the release pin")
    runtime_root.mkdir(parents=True, exist_ok=True)
    target = runtime_root / pin["sourceRevision"]
    if target.exists() or target.is_symlink():
        if target.is_symlink():
            raise RestoreError("Existing runtime target is a symlink; it was preserved")
        verify_checkout(target, package, pin)
        return target
    with tempfile.TemporaryDirectory(prefix=".restore-", dir=runtime_root) as staging_name:
        staging = Path(staging_name) / "checkout"
        subprocess.run(["git", "clone", "--quiet", "--no-checkout", "--no-hardlinks", "--", repository, str(staging)], check=True)
        subprocess.run(["git", "-C", str(staging), "checkout", "--quiet", "--detach", pin["sourceRevision"]], check=True)
        with (staging / ".git/info/exclude").open("a") as excluded:
            excluded.write("\n/node_modules\n")
        (staging / "node_modules").symlink_to(package / "share/vault-services/node_modules", target_is_directory=True)
        verify_checkout(staging, package, pin)
        publish_checkout(staging, target)
    return target


def main():
    flake = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", type=Path, default=flake / "home/services/shared-vault-prl-dev-vm-release.json")
    parser.add_argument("--archive", type=Path, help="Use a retained archive instead of downloading")
    parser.add_argument("--archive-only", action="store_true", help="Import the verified archive without building or restoring the source checkout")
    parser.add_argument("--source-repository", default="git@github-work:andrearagao/fulcrum.git")
    parser.add_argument("--runtime-root", type=Path, default=Path.home() / "projects/work/fulcrum-releases")
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
        attribute = "#nixosConfigurations.prl-dev-vm.config.home-manager.users.aragao.my.sharedVault.release"
        build = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", str(flake) + attribute], check=True, capture_output=True, text=True)
        paths = build.stdout.splitlines()
        if len(paths) != 1:
            raise RestoreError("Expected one Nix runtime package")
        package = Path(paths[0])
        result["package"] = str(package)
        result["checkout"] = str(restore_checkout(args.source_repository, args.runtime_root, package, pin))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except subprocess.SubprocessError:
        raise SystemExit("Restore failed: a required command failed; review its diagnostic output") from None
    except (RestoreError, OSError, ValueError) as error:
        raise SystemExit("Restore failed: " + str(error)) from None
