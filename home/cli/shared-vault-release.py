#!/usr/bin/env python3
"""Build an immutable shared-vault archive from a checked Fulcrum release."""

import argparse
import base64
from contextlib import contextmanager
import ctypes
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import uuid


ROOT_NAME = "shared-vault-release"
SCRIPTS = {
    "vault-client": "vault.ts",
    "vault-mcp": "vault-mcp.ts",
}
NATIVE_BINARIES = ("shared-vault", "shared-vault-grammar")
REQUIRED_SOURCE = {
    "package.json",
    "bun.lock",
    "Cargo.toml",
    "Cargo.lock",
    "services/shared-vault/Cargo.toml",
    "services/shared-vault/flake.nix",
    "services/shared-vault/flake.lock",
    "services/shared-vault/src/main.rs",
    "services/shared-vault/src/bin/shared-vault-grammar.rs",
    "services/shared-vault/helpers/document-extraction.ts",
    "scripts/development-certification.ts",
    "scripts/verify-installed-dependencies.ts",
    "scripts/verify-installed-patches.ts",
    "scripts/automation-runner-bootstrap.ts",
    *(f"scripts/{script}" for script in SCRIPTS.values()),
}
DENIED_NAMES = {".git", ".cache", ".npmrc", ".netrc", ".pypirc", "auth.json", "credentials.json"}
DENIED_ROOTS = {"secrets", "backups", "data", ".fulcrum"}
INVENTORY_PREFIX = b"fulcrum-installed-dependencies-v1\0"
CARGO_REGISTRY = "index.crates.io-1949cf8c6b5b557f"
CARGO_SOURCE = "registry+https://github.com/rust-lang/crates.io-index"
SDK_REVISION = "4fe25e12eb9f4c744966dd3de5a05246cf098601"
SDK_NAR_HASH = "sha256-WrSODdZFVIs/Hh2NzC0bY+ROByi0bATg8WfePX8dPj8="
CERT_BUN_STORE_ROOT = Path("/nix/store")
MANAGED_CONTROL_VARIABLES = (
    "PLAYWRIGHT_BROWSERS_PATH", "CHROMIUM_BIN", "FULCRUM_CHROMIUM_PATH", "FULCRUM_TRIVY_BIN",
    "FULCRUM_OCR_EXEC", "FULCRUM_OFFICE_EXEC", "TESSDATA_PREFIX", "FULCRUM_CERT_BUN_BIN",
    "LOG_LEVEL", "CI", "TZ",
)
COMMAND_ENVIRONMENT_KEYS = set(MANAGED_CONTROL_VARIABLES) | {
    "PATH", "HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR", "LANG", "NIX_CONFIG",
    "BUN_CONFIG_NO_CLEAR_TERMINAL", "BUN_RUNTIME_TRANSPILER_CACHE_PATH",
    "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_OPTIONAL_LOCKS",
    "CARGO_ENCODED_RUSTFLAGS", "CFLAGS", "CXXFLAGS", "CC_SHELL_ESCAPED_FLAGS", "NOSYSBASHRC",
}


class ReleaseError(Exception):
    pass


class UnsettledVerifier(ReleaseError):
    def __init__(self, message: str, supervisor_pid: int):
        super().__init__(message)
        self.supervisor_pid = supervisor_pid


def direct_children() -> list[int]:
    path = Path(f"/proc/self/task/{os.getpid()}/children")
    return [int(pid) for pid in path.read_text().split()]


def reap_exited_children() -> None:
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return


def terminate_checker(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait()


def drain_descendants() -> bool:
    found = False
    grace = time.monotonic() + 5
    while True:
        reap_exited_children()
        children = direct_children()
        if not children:
            return found
        found = True
        for pid in children:
            try:
                os.kill(pid, signal.SIGTERM if time.monotonic() < grace else signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(0.05)


def supervise_command(args: list[str], cwd: Path, timeout: int, stdout, stderr,
                      ready_fd: int, previous_mask: set[signal.Signals],
                      environment: dict[str, str]) -> int:
    process = None
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            os.write(ready_fd, b"E")
            return 125
        direct_children()  # Refuse to start a verifier without the ownership view.
        cancelled = False

        def cancel(_signal, _frame):
            nonlocal cancelled
            cancelled = True

        signal.signal(signal.SIGINT, cancel)
        signal.signal(signal.SIGTERM, cancel)
        os.write(ready_fd, b"R")
        os.close(ready_fd)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        if cancelled:
            return 130
        process = subprocess.Popen(args, cwd=cwd, env=environment, stdout=stdout, stderr=stderr,
                                   start_new_session=True)
        deadline = time.monotonic() + timeout
        while process.poll() is None and not cancelled and time.monotonic() < deadline:
            time.sleep(0.05)
        timed_out = not cancelled and process.poll() is None
        if cancelled or timed_out:
            terminate_checker(process)
        else:
            process.wait()
        orphaned = drain_descendants()
        if cancelled:
            return 130
        if timed_out:
            return 124
        return 1 if process.returncode != 0 or orphaned else 0
    except BaseException:
        if process is not None:
            try:
                terminate_checker(process)
                drain_descendants()
            except BaseException:
                while True:
                    time.sleep(60)  # Keep ownership when closure cannot be proved.
        return 125


def wait_supervisor(pid: int, deadline: float) -> int | None:
    while True:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited:
            return status
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.05)


def selected_bun_directory() -> Path | None:
    raw = os.environ.get("FULCRUM_CERT_BUN_BIN")
    if raw is None:
        return None
    selected = Path(raw)
    if not selected.is_absolute() or selected.parent != CERT_BUN_STORE_ROOT:
        raise ReleaseError("certified Bun selector must name a Nix store directory")
    try:
        for parent in (CERT_BUN_STORE_ROOT.parent, CERT_BUN_STORE_ROOT):
            if parent.resolve(strict=True) != parent or not parent.is_dir() or os.access(parent, os.W_OK):
                raise ReleaseError("certified Bun store parents are not immutable")
        if selected.resolve(strict=True) != selected:
            raise ReleaseError("certified Bun directory is not canonical")
        directory = selected.lstat()
        entries = list(selected.iterdir())
        binary = (selected / "bun").lstat()
    except (OSError, RuntimeError) as error:
        raise ReleaseError("certified Bun directory is unavailable") from error
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_mode & 0o222
            or os.access(selected, os.W_OK) or len(entries) != 1 or entries[0].name != "bun"
            or not stat.S_ISREG(binary.st_mode) or binary.st_mode & 0o222
            or not binary.st_mode & 0o111 or not os.access(selected / "bun", os.X_OK)):
        raise ReleaseError("certified Bun directory must contain only immutable executable bun")
    return selected


def require_selected_bun_matches(root: Path) -> None:
    selected = selected_bun_directory()
    if selected is None:
        return
    pinned = root / "node_modules" / "bun" / "bin" / "bun.exe"
    try:
        matches = (not pinned.is_symlink() and pinned.is_file()
                   and file_digest(selected / "bun") == file_digest(pinned))
    except OSError as error:
        raise ReleaseError("certified Bun selector or project pin is unreadable") from error
    if not matches:
        raise ReleaseError("certified Bun selector differs from the project pin")


def managed_path() -> str:
    def immutable_directory(path: Path) -> str | None:
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError):
            return None
        if (not str(resolved).startswith("/nix/store/") or not resolved.is_dir()
                or resolved.stat().st_mode & 0o222):
            return None
        return str(resolved)

    try:
        user_name = pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        user_name = None
    profile = Path("/etc/profiles/per-user") / user_name / "bin" if user_name else None
    system = Path("/run/current-system/sw/bin")
    if profile is not None and profile.exists() and system.exists():
        selected = [immutable_directory(profile), immutable_directory(system)]
        if any(value is None for value in selected):
            raise ReleaseError("managed executable profiles are not immutable")
        directories = selected

    else:
        # A Nix sandbox exposes its declared tools as direct store paths.
        directories = []
        for component in os.environ.get("PATH", "").split(":"):
            if not component or not component.startswith("/"):
                continue
            name = immutable_directory(Path(component))
            if name is None:
                continue
            if name not in directories:
                directories.append(name)
        if not directories:
            raise ReleaseError("no immutable managed executable path is available")

    bun = selected_bun_directory()
    if bun is not None:
        directories = [str(bun), *(directory for directory in directories if directory != str(bun))]
    return ":".join(directories)


def managed_command_environment() -> dict[str, str]:
    environment = {key: os.environ[key] for key in MANAGED_CONTROL_VARIABLES if key in os.environ}
    environment.update({
        "PATH": managed_path(),
        "HOME": "/var/empty",
        "XDG_CONFIG_HOME": "/var/empty",
        "XDG_CACHE_HOME": "/var/empty",
        "TMPDIR": "/tmp",
        "LANG": "C.UTF-8",
        "BUN_CONFIG_NO_CLEAR_TERMINAL": "1",
        "BUN_RUNTIME_TRANSPILER_CACHE_PATH": "0",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_OPTIONAL_LOCKS": "0",
    })
    return environment


def command(args: list[str], cwd: Path, phase: str, timeout: int = 900,
            environment: dict[str, str] | None = None,
            build_paths: tuple[Path, Path, Path] | None = None) -> bytes:
    if not sys.platform.startswith("linux"):
        raise ReleaseError("release verifier supervision requires Linux")
    environment = dict(managed_command_environment() if environment is None else environment)
    flag_names = ("CARGO_ENCODED_RUSTFLAGS", "CFLAGS", "CXXFLAGS", "CC_SHELL_ESCAPED_FLAGS")
    if build_paths is None:
        if any(name in environment for name in flag_names) or "NOSYSBASHRC" in environment:
            raise ReleaseError("build flags are only allowed for the derived native build")
    elif (phase != "certified native Cargo build" or environment.get("NOSYSBASHRC") != "1"
          or {name: environment.get(name) for name in flag_names} != native_build_path_flags(*build_paths)):
        raise ReleaseError("native build flags differ from the derived paths")
    if (set(environment) - COMMAND_ENVIRONMENT_KEYS or environment.get("PATH") != managed_path()
            or environment.get("FULCRUM_CERT_BUN_BIN") != os.environ.get("FULCRUM_CERT_BUN_BIN")
            or environment.get("NIX_CONFIG") not in (None, "experimental-features = nix-command flakes\n")):
        raise ReleaseError("supervised command has an unsupported environment override")
    pid = None
    status = None
    read_fd, write_fd = os.pipe()
    try:
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            with blocked_publication_signals() as previous_mask:
                pid = os.fork()
                if pid == 0:
                    os.close(read_fd)
                    result = supervise_command(args, cwd, timeout, stdout, stderr,
                                               write_fd, previous_mask, environment)
                    os._exit(result)
                os.close(write_fd)
                write_fd = -1
                ready = os.read(read_fd, 1)
            if ready != b"R":
                status = wait_supervisor(pid, time.monotonic() + 5)
                if status is None:
                    raise UnsettledVerifier(f"{phase} supervisor setup remains active", pid)
                raise ReleaseError(f"{phase} supervisor unavailable")
            status = wait_supervisor(pid, time.monotonic() + timeout + 15)
            if status is None:
                os.kill(pid, signal.SIGTERM)
                status = wait_supervisor(pid, time.monotonic() + 15)
                if status is None:
                    raise UnsettledVerifier(f"{phase} verifier closure unproved", pid)
            if not os.WIFEXITED(status):
                raise UnsettledVerifier(f"{phase} supervisor exited without closure proof", pid)
            outcome = os.WEXITSTATUS(status)
            if outcome == 0:
                stdout.seek(0)
                return stdout.read()
            if outcome == 1:
                raise ReleaseError(f"{phase} failed")
            if outcome in (124, 125, 130):
                raise ReleaseError(f"{phase} unavailable")
            raise UnsettledVerifier(f"{phase} supervisor returned an unknown state", pid)
    except BaseException as error:
        if isinstance(error, UnsettledVerifier):
            raise
        if pid is not None and status is None:
            with blocked_publication_signals():
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    status = wait_supervisor(pid, time.monotonic() + 15)
                except ChildProcessError:
                    status = None
            if status is None or not os.WIFEXITED(status):
                raise UnsettledVerifier(f"{phase} verifier closure unproved", pid) from error
        if isinstance(error, ReleaseError):
            raise
        raise ReleaseError(f"{phase} unavailable") from error
    finally:
        os.close(read_fd)
        if write_fd != -1:
            os.close(write_fd)


def private_directory(path: Path) -> Path:
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise ReleaseError("state directory must be an existing private absolute directory")
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ReleaseError("state directory is not private to the current user")
    return path.resolve(strict=True)


def checked_paths(worktree: Path, receipt: Path, output: Path, state: Path) -> tuple[Path, Path, Path, Path]:
    state = private_directory(state)
    if not worktree.is_absolute() or worktree.is_symlink() or not worktree.is_dir():
        raise ReleaseError("worktree must be an absolute repository root")
    worktree = worktree.resolve(strict=True)
    if not receipt.is_absolute() or receipt.is_symlink() or not receipt.is_file():
        raise ReleaseError("receipt must be an existing regular absolute file")
    receipt = receipt.resolve(strict=True)
    if not output.is_absolute() or output.parent != state or not output.name.endswith(".tar.gz"):
        raise ReleaseError("output must be a .tar.gz directly inside the private state directory")
    sidecar = output.with_name(output.name + ".sha256")
    if output.exists() or output.is_symlink() or sidecar.exists() or sidecar.is_symlink():
        raise ReleaseError("release output already exists")
    if worktree == state or state.is_relative_to(worktree) or worktree.is_relative_to(state):
        raise ReleaseError("release state must be separate from the source checkout")
    return worktree, receipt, output, state


def clean_revision(worktree: Path) -> str:
    root = command(["git", "--no-replace-objects", "rev-parse", "--show-toplevel"], worktree, "Git root").decode().strip()
    if root != str(worktree):
        raise ReleaseError("worktree is not its repository root")
    revision = command(["git", "--no-replace-objects", "rev-parse", "HEAD"], worktree, "Git revision").decode().strip()
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ReleaseError("source revision must be a full SHA-1 commit")
    if command(["git", "--no-replace-objects", "status", "--porcelain", "--untracked-files=all"], worktree, "Git status"):
        raise ReleaseError("source checkout is dirty")
    for name, mode, object_id in committed_source(worktree, revision):
        if raw_worktree_blob(worktree, name, mode) != object_id:
            raise ReleaseError("materialized source differs from the committed raw bytes")
    return revision


def native_target() -> tuple[str, int]:
    if not sys.platform.startswith("linux"):
        raise ReleaseError("native shared vault release requires Linux")
    machine = {"x86_64": ("x86_64-linux", 62), "aarch64": ("aarch64-linux", 183)}.get(os.uname().machine)
    if machine is None:
        raise ReleaseError("unsupported native shared vault target")
    return machine


def certified_native(raw: dict, checked: dict, revision: str) -> dict[str, str]:
    evidence = raw.get("nativeArtifacts")
    if not isinstance(evidence, dict) or checked.get("nativeArtifacts") != evidence:
        raise ReleaseError("receipt check did not bind native artifacts")
    if set(evidence) != {"schema", "candidate", "target", "binaries"}:
        raise ReleaseError("native artifact evidence has unexpected fields")
    if (evidence["schema"] != "fulcrum.shared-vault.native.v1"
            or evidence["candidate"] != revision or evidence["target"] != native_target()[0]):
        raise ReleaseError("native artifact evidence is not for this source and target")
    binaries = evidence["binaries"]
    if (not isinstance(binaries, dict) or set(binaries) != set(NATIVE_BINARIES)
            or any(not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{64}", value)
                   for value in binaries.values())):
        raise ReleaseError("native artifact hashes are missing or invalid")
    return binaries


def certificate(worktree: Path, receipt: Path, bun: Path, revision: str) -> tuple[str, str, str, dict[str, str]]:
    if bun.is_symlink() or not bun.is_file() or not os.access(bun, os.X_OK):
        raise ReleaseError("pinned Bun executable is unavailable")
    require_selected_bun_matches(worktree)
    package = json.loads((worktree / "package.json").read_text())
    version = package.get("version")
    bun_version = package.get("packageManager")
    if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", version):
        raise ReleaseError("invalid package version")
    if not isinstance(bun_version, str) or not re.fullmatch(r"bun@[0-9]+\.[0-9]+\.[0-9]+", bun_version):
        raise ReleaseError("package does not pin Bun")
    observed_bun = command([str(bun), "--version"], worktree, "pinned Bun version").decode().strip()
    if observed_bun != bun_version.removeprefix("bun@"):
        raise ReleaseError("pinned Bun version does not match package")

    if receipt.stat().st_size > 16 * 1024 * 1024:
        raise ReleaseError("certification receipt exceeds the packaging bound")
    receipt_bytes = receipt.read_bytes()
    result = command([str(bun), "--no-env-file", "scripts/development-certification.ts",
                      "check", "--receipt", str(receipt)], worktree, "certification receipt check")
    if receipt.read_bytes() != receipt_bytes:
        raise ReleaseError("certification receipt changed during its check")
    try:
        checked = json.loads(result)
        raw = json.loads(receipt_bytes)
    except (ValueError, OSError) as error:
        raise ReleaseError("certification result is unreadable") from error
    if not isinstance(checked, dict) or not isinstance(raw, dict):
        raise ReleaseError("certification result is invalid")
    if (checked.get("status") != "PASS" or checked.get("candidate") != revision
            or raw.get("schema") != "fulcrum.certification.v1" or raw.get("status") != "PASS"
            or raw.get("profile") not in ("release", "focused") or raw.get("candidate") != revision
            or raw.get("worktree") != str(worktree)):
        raise ReleaseError("receipt does not certify this exact release checkout")
    dependency_sha = raw.get("installedDependenciesSha256")
    if (not isinstance(dependency_sha, str) or not re.fullmatch(r"[a-f0-9]{64}", dependency_sha)
            or checked.get("installedDependenciesSha256") != dependency_sha):
        raise ReleaseError("receipt does not bind the installed dependency bytes")
    native_hashes = certified_native(raw, checked, revision)
    return version, hashlib.sha256(receipt_bytes).hexdigest(), dependency_sha, native_hashes


def allowed_path(name: str) -> bool:
    parts = name.split("/")
    if not parts or name.startswith("/") or "\\" in name or any(part in ("", ".", "..") for part in parts):
        raise ReleaseError("Git archive contains an unsafe path")
    if any(part in DENIED_NAMES or part.startswith(".env") for part in parts):
        return False
    if parts[0] in DENIED_ROOTS:
        return False
    return True


def git_object_id(kind: str, contents: bytes) -> str:
    return hashlib.sha1(f"{kind} {len(contents)}\0".encode() + contents).hexdigest()


def source_tree_id(entries: list[tuple[str, str, str]]) -> str:
    root = {}
    for name, mode, object_id in entries:
        node = root
        parts = name.split("/")
        for part in parts[:-1]:
            node = node.setdefault(part, {})
            if not isinstance(node, dict):
                raise ReleaseError("committed source contains conflicting paths")
        if parts[-1] in node:
            raise ReleaseError("committed source contains duplicate paths")
        node[parts[-1]] = (mode, object_id)

    def tree_id(node):
        contents = bytearray()
        for name, entry in sorted(node.items(), key=lambda item: item[0].encode() + (b"/" if isinstance(item[1], dict) else b"")):
            mode, object_id = ("40000", tree_id(entry)) if isinstance(entry, dict) else entry
            contents.extend(mode.encode() + b" " + name.encode() + b"\0" + bytes.fromhex(object_id))
        return git_object_id("tree", contents)
    return tree_id(root)


def committed_source(worktree: Path, revision: str) -> list[tuple[str, str, str]]:
    commit = command(["git", "--no-replace-objects", "cat-file", "commit", revision], worktree, "committed source identity")
    if git_object_id("commit", commit) != revision:
        raise ReleaseError("Git commit contents do not match the candidate identity")
    tree_line = commit.split(b"\n", 1)[0]
    if not re.fullmatch(rb"tree [a-f0-9]{40}", tree_line):
        raise ReleaseError("Git commit has no valid source tree")
    tree = command(["git", "--no-replace-objects", "ls-tree", "-r", "-z", "--full-tree", revision],
                   worktree, "committed source inventory")
    entries = []
    for record in tree.split(b"\0"):
        if not record:
            continue
        try:
            metadata, name_bytes = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ")
            name = name_bytes.decode("utf-8")
        except (UnicodeError, ValueError) as error:
            raise ReleaseError("committed source inventory is invalid") from error
        if name != ".env.example" and not allowed_path(name):
            raise ReleaseError("tracked source contains a private or mutable path")
        if kind != "blob" or mode not in ("100644", "100755") or not re.fullmatch(r"[a-f0-9]{40}", object_id):
            raise ReleaseError("tracked source contains a link or unsupported file")
        entries.append((name, mode, object_id))
    if source_tree_id(entries).encode() != tree_line[5:]:
        raise ReleaseError("Git source tree does not match the candidate commit")
    return entries


def raw_worktree_blob(worktree: Path, name: str, mode: str) -> str:
    parts = PurePosixPath(name).parts
    descriptors = []
    try:
        directory = os.open(worktree, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(directory)
        for part in parts[:-1]:
            directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            descriptors.append(directory)
        source = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        descriptors.append(source)
        before = os.fstat(source)
        if not stat.S_ISREG(before.st_mode) or bool(before.st_mode & 0o111) != (mode == "100755"):
            raise ReleaseError("materialized source type or executable mode differs from commit")
        digest = hashlib.sha1()
        digest.update(f"blob {before.st_size}\0".encode())
        while block := os.read(source, 1024 * 1024):
            digest.update(block)
        after = os.fstat(source)
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                                 info.st_ctime_ns, info.st_mode)
        current = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
        if identity(before) != identity(after) or identity(before) != identity(current):
            raise ReleaseError("materialized source changed while reading")
        for index, descriptor in enumerate(descriptors[:-1]):
            opened = os.fstat(descriptor)
            current_path = worktree.joinpath(*parts[:index])
            current_parent = current_path.lstat()
            if (opened.st_dev, opened.st_ino) != (current_parent.st_dev, current_parent.st_ino):
                raise ReleaseError("materialized source parent changed while reading")
        return digest.hexdigest()
    except OSError as error:
        raise ReleaseError("materialized source is missing or unsafe") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def export_tracked_source(worktree: Path, revision: str, destination: Path) -> dict[str, tuple[str, int, int, str]]:
    expected = {}
    for name, mode, object_id in committed_source(worktree, revision):
        if name == ".env.example":
            continue
        target = destination.joinpath(*PurePosixPath(name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        contents = command(["git", "--no-replace-objects", "cat-file", "blob", object_id], worktree, "committed source blob")
        if git_object_id("blob", contents) != object_id:
            raise ReleaseError("Git blob contents do not match the committed identity")
        with target.open("xb") as output:
            output.write(contents)
        permissions = 0o755 if mode == "100755" else 0o644
        target.chmod(permissions)
        expected[name] = ("file", permissions, len(contents), hashlib.sha256(contents).hexdigest())
    if not all((destination / name).is_file() for name in REQUIRED_SOURCE):
        raise ReleaseError("tracked source is missing a required runtime or verification file")
    return expected


def dependency_files(root: Path):
    if root.is_symlink() or not root.is_dir():
        raise ReleaseError("node_modules must be a real directory")
    regular = set()
    links = []
    entries = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        files.sort()
        parent = Path(directory)
        for name in dirs[:]:
            child = parent / name
            if name == ".cache":
                dirs.remove(name)
                continue
            if not allowed_path(child.relative_to(root).as_posix()):
                raise ReleaseError("dependency tree contains a private path")
            if child.is_symlink():
                raise ReleaseError("dependency directory link requires explicit packaging")
        for name in files:
            child = parent / name
            if not allowed_path(child.relative_to(root).as_posix()):
                raise ReleaseError("dependency tree contains a private path")
            info = child.lstat()
            if stat.S_ISLNK(info.st_mode):
                link = os.readlink(child)
                if os.path.isabs(link):
                    raise ReleaseError("dependency link leaves the package tree")
                links.append((child.relative_to(root), child))
            elif not stat.S_ISREG(info.st_mode):
                raise ReleaseError("dependency tree contains an unsupported file")
            else:
                regular.add(child.relative_to(root).as_posix())
            entries.append((child.relative_to(root), child))
    for _, child in links:
        try:
            resolved = child.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ReleaseError("dependency link is broken or cyclic") from error
        if not resolved.is_relative_to(root) or not resolved.is_file():
            raise ReleaseError("dependency link leaves the package tree")
        canonical = resolved.relative_to(root).as_posix()
        if not allowed_path(canonical) or canonical not in regular:
            raise ReleaseError("dependency link targets excluded or unapproved data")
    return entries


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory_dependencies(root: Path) -> str:
    digest = hashlib.sha256(INVENTORY_PREFIX)
    entries = sorted(dependency_files(root), key=lambda entry: entry[0].as_posix().encode("utf-8"))
    for relative, path in entries:
        name = relative.as_posix().encode("utf-8")
        if len(name) >= 2**32:
            raise ReleaseError("dependency path exceeds inventory bound")
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(b"\1" if path.stat().st_mode & 0o111 else b"\0")
        digest.update(bytes.fromhex(file_digest(path)))
    return digest.hexdigest()


def copy_dependencies(source: Path, destination: Path) -> None:
    for relative, path in dependency_files(source):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target, follow_symlinks=True)
        target.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)


def verify_dependencies(root: Path, bun: Path) -> None:
    require_selected_bun_matches(root)
    for script in ("verify-installed-dependencies.ts", "verify-installed-patches.ts"):
        command([str(bun), "--no-env-file", f"scripts/{script}"], root,
                f"installed dependency verification ({script})")


def native_build_path_flags(source_root: Path, cargo_home: Path, cargo_target_dir: Path) -> dict[str, str]:
    mappings = ((source_root, "/src/fulcrum"), (cargo_home, "/cargo-home"),
                (cargo_target_dir, "/cargo-target"))
    for path, _ in mappings:
        text = str(path)
        if (not path.is_absolute() or re.search(r"[=\x00-\x1f\x7f]", text)
                or path.resolve(strict=True) != path or not path.is_dir()):
            raise ReleaseError("native build path is not a canonical safe directory")
    encoded = "\x1f".join(f"--remap-path-prefix={path}={destination}" for path, destination in mappings)
    def quote(argument: str) -> str:
        return "'" + argument.replace("'", "'\"'\"'") + "'"
    cflags = " ".join(quote(f"-ffile-prefix-map={path}={destination}") for path, destination in mappings)
    return {"CARGO_ENCODED_RUSTFLAGS": encoded, "CFLAGS": cflags, "CXXFLAGS": cflags,
            "CC_SHELL_ESCAPED_FLAGS": "1"}


def checked_cache_directory(path: Path) -> None:
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ReleaseError("Cargo registry cache path is not canonical")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ReleaseError("Cargo registry cache directory is unsafe")


def reject_ancestor_cargo_configuration(cwd: Path) -> None:
    for ancestor in (cwd, *cwd.parents):
        cargo_directory = ancestor / ".cargo"
        if cargo_directory.is_symlink():
            raise ReleaseError("Cargo build cwd has a linked ancestor configuration directory")
        for name in ("config", "config.toml"):
            path = cargo_directory / name
            if path.exists() or path.is_symlink():
                raise ReleaseError("Cargo build cwd has an ancestor configuration override")


def copy_cache_file(source: Path, target: Path, expected_hash: str | None, maximum: int,
                    capture: bool = False) -> bytes:
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum or before.st_mode & 0o6000:
            raise ReleaseError("Cargo registry cache file is unsafe")
        digest = hashlib.sha256()
        contents = bytearray()
        copied = 0
        with target.open("xb") as output:
            while block := os.read(descriptor, 1024 * 1024):
                copied += len(block)
                if copied > maximum:
                    raise ReleaseError("Cargo registry cache file exceeds bound")
                if capture:
                    contents.extend(block)
                digest.update(block)
                output.write(block)
        after = os.fstat(descriptor)
        named = source.lstat()
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                                 info.st_ctime_ns, info.st_mode)
        if identity(before) != identity(after) or identity(before) != identity(named):
            raise ReleaseError("Cargo registry cache file changed during copy")
        if expected_hash is not None and digest.hexdigest() != expected_hash:
            raise ReleaseError("Cargo crate bytes differ from committed Cargo.lock")
        target.chmod(0o644)
        return bytes(contents)
    finally:
        os.close(descriptor)


def cargo_index_path(name: str) -> Path:
    if len(name) == 1:
        return Path("1") / name
    if len(name) == 2:
        return Path("2") / name
    if len(name) == 3:
        return Path("3") / name[0] / name
    return Path(name[:2]) / name[2:4] / name


def prepare_cargo_home(app: Path, destination: Path) -> None:
    sdk_lock = json.loads((app / "services/shared-vault/flake.lock").read_text())
    locked = sdk_lock["nodes"]["nixpkgs"]["locked"]
    if (locked.get("rev") != SDK_REVISION or locked.get("narHash") != SDK_NAR_HASH
            or f"github:NixOS/nixpkgs/{SDK_REVISION}" not in (app / "services/shared-vault/flake.nix").read_text()):
        raise ReleaseError("native SDK differs from the reviewed pinned toolchain")
    cargo_lock = tomllib.loads((app / "Cargo.lock").read_text())
    if cargo_lock.get("version") != 4 or not isinstance(cargo_lock.get("package"), list):
        raise ReleaseError("Cargo.lock is missing a supported locked dependency inventory")
    cache_home = Path(os.environ.get("CARGO_HOME", str(Path.home() / ".cargo")))
    checked_cache_directory(cache_home)
    source_cache = cache_home / "registry" / "cache" / CARGO_REGISTRY
    source_index = cache_home / "registry" / "index" / CARGO_REGISTRY
    for directory in (cache_home / "registry", cache_home / "registry/cache", source_cache,
                      cache_home / "registry/index", source_index, source_index / ".cache"):
        checked_cache_directory(directory)
    if destination.exists() or destination.is_symlink():
        raise ReleaseError("private Cargo home is not fresh")
    destination.mkdir(mode=0o700)
    (destination / "registry/index" / CARGO_REGISTRY).mkdir(parents=True)
    (destination / "registry/index" / CARGO_REGISTRY / "config.json").write_text(
        '{"dl":"https://static.crates.io/crates","api":"https://crates.io"}\n')
    seen = set()
    for package in cargo_lock["package"]:
        if not isinstance(package, dict):
            raise ReleaseError("Cargo.lock package is invalid")
        if "source" not in package:
            continue
        name, version, checksum = (package.get(key) for key in ("name", "version", "checksum"))
        if (package.get("source") != CARGO_SOURCE or not isinstance(name, str)
                or not re.fullmatch(r"[A-Za-z0-9_-]+", name) or not isinstance(version, str)
                or not re.fullmatch(r"[A-Za-z0-9.+_-]+", version) or not isinstance(checksum, str)
                or not re.fullmatch(r"[a-f0-9]{64}", checksum) or (name, version) in seen):
            raise ReleaseError("Cargo.lock has an unsupported or duplicate dependency")
        seen.add((name, version))
        crate = f"{name}-{version}.crate"
        copy_cache_file(source_cache / crate, destination / "registry/cache" / CARGO_REGISTRY / crate,
                        checksum, 128 * 1024 * 1024)
        index = cargo_index_path(name)
        index_parent = source_index / ".cache"
        for component in index.parts[:-1]:
            index_parent /= component
            checked_cache_directory(index_parent)
        index_target = destination / "registry/index" / CARGO_REGISTRY / ".cache" / index
        if not index_target.exists():
            data = copy_cache_file(source_index / ".cache" / index, index_target, None,
                                   8 * 1024 * 1024, capture=True)
        else:
            data = index_target.read_bytes()
        fields = data.split(b"\0")
        matches = []
        for position, field in enumerate(fields[:-1]):
            if field == version.encode():
                try:
                    matches.append(json.loads(fields[position + 1]))
                except ValueError as error:
                    raise ReleaseError("Cargo registry index record is invalid") from error
        if (not data.startswith(b"\x03\x02\0\0\0") or len(matches) != 1
                or matches[0].get("name") != name or matches[0].get("vers") != version
                or matches[0].get("cksum") != checksum):
            raise ReleaseError("Cargo registry index differs from committed Cargo.lock")


def checked_native_binary(path: Path, expected_hash: str, single_link: bool = False) -> tuple[str, int, int, str]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        named = path.lstat()
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                                 info.st_ctime_ns, info.st_mode, info.st_nlink)
        if (not stat.S_ISREG(before.st_mode) or stat.S_IMODE(before.st_mode) != 0o755
                or before.st_uid != os.getuid() or single_link and before.st_nlink != 1
                or identity(before) != identity(named)):
            raise ReleaseError("native binary is missing, linked or has unexpected permissions")
        header = os.read(descriptor, 20)
        machine = native_target()[1]
        if (len(header) != 20 or header[:4] != b"\x7fELF" or header[4:6] != b"\x02\x01"
                or int.from_bytes(header[16:18], "little") not in (2, 3)
                or int.from_bytes(header[18:20], "little") != machine):
            raise ReleaseError("native binary is not an executable for the certified target")
        digest = hashlib.sha256(header)
        while block := os.read(descriptor, 1024 * 1024):
            digest.update(block)
        after = os.fstat(descriptor)
        named = path.lstat()
        if identity(before) != identity(after) or identity(before) != identity(named):
            raise ReleaseError("native binary changed during hashing")
        if digest.hexdigest() != expected_hash:
            raise ReleaseError("native binary bytes differ from certification")
        return "file", 0o755, before.st_size, expected_hash
    finally:
        os.close(descriptor)


def build_native(app: Path, temporary: Path, binaries: dict[str, str]) -> tuple[Path, dict[str, tuple[str, int, int, str]]]:
    target_dir = temporary / "cargo-target"
    if target_dir.exists() or target_dir.is_symlink():
        raise ReleaseError("native build target is not fresh")
    target_dir.mkdir(mode=0o700)
    cargo_home = temporary / "cargo-home"
    prepare_cargo_home(app, cargo_home)
    cwd = temporary / "cargo-cwd"
    cwd.mkdir(mode=0o700)
    reject_ancestor_cargo_configuration(cwd)
    build_home = temporary / "build-home"
    build_home.mkdir(mode=0o700)
    scratch = temporary / "build-tmp"
    scratch.mkdir(mode=0o700)
    nix = Path("/run/current-system/sw/bin/nix").resolve(strict=True)
    if not str(nix).startswith("/nix/store/") or not nix.is_file() or not os.access(nix, os.X_OK):
        raise ReleaseError("managed Nix command is unavailable")
    environment = {
        "PATH": managed_path(),
        "HOME": str(build_home),
        "XDG_CONFIG_HOME": str(build_home / ".config"),
        "XDG_CACHE_HOME": str(build_home / ".cache"),
        "TMPDIR": str(scratch),
        "LANG": "C.UTF-8",
        "NIX_CONFIG": "experimental-features = nix-command flakes\n",
        "NOSYSBASHRC": "1",
    }
    flags = native_build_path_flags(app, cargo_home, target_dir)
    environment.update(flags)
    if "FULCRUM_CERT_BUN_BIN" in os.environ:
        environment["FULCRUM_CERT_BUN_BIN"] = os.environ["FULCRUM_CERT_BUN_BIN"]
    shell = (
        'cargo=$(command -v cargo); rustc=$(command -v rustc); linker=$(command -v cc); '
        'case "$cargo:$rustc:$linker" in /nix/store/*:/nix/store/*:/nix/store/*) ;; *) exit 125;; esac; '
        'test "$("$cargo" --version | cut -d" " -f2)" = 1.99.0; '
        'test "$("$rustc" --version | cut -d" " -f2)" = 1.99.0; '
        'test "$(pkg-config --modversion icu-i18n)" = 78.3; '
        'test "$linker" = "${CC:-}"; '
        'test "$(pwd -P)" = "$5"; '
        'export CARGO_HOME="$1" CARGO_TARGET_DIR="$2" CARGO_NET_OFFLINE=true RUSTC="$rustc"; '
        'export "CARGO_TARGET_$3_LINKER=$linker"; '
        'exec "$cargo" build --release --locked --offline --package shared-vault '
        '--manifest-path "$4" --bin shared-vault --bin shared-vault-grammar'
    )
    target_variable = "X86_64_UNKNOWN_LINUX_GNU" if native_target()[0] == "x86_64-linux" else "AARCH64_UNKNOWN_LINUX_GNU"
    command([str(nix), "develop", "--no-write-lock-file", f"path:{app / 'services/shared-vault'}",
             "--command", "env", "NOSYSBASHRC=1", *(f"{name}={value}" for name, value in flags.items()),
             "sh", "-eu", "-c", shell, "sh", str(cargo_home), str(target_dir),
             target_variable, str(app / "Cargo.toml"), str(cwd)], cwd, "certified native Cargo build",
            timeout=3600, environment=environment, build_paths=(app, cargo_home, target_dir))
    reject_ancestor_cargo_configuration(cwd)
    built = {name: target_dir / "release" / name for name in NATIVE_BINARIES}
    entries = {name: checked_native_binary(path, binaries[name]) for name, path in built.items()}
    attested = temporary / "native-attested"
    attested.mkdir(mode=0o700)
    for name in NATIVE_BINARIES:
        shutil.copyfile(built[name], attested / name)
        (attested / name).chmod(0o755)
        checked_native_binary(attested / name, binaries[name], single_link=True)
    completeness_environment = {
        "PATH": environment["PATH"],
        "HOME": environment["HOME"],
        "TMPDIR": environment["TMPDIR"],
        "LANG": environment["LANG"],
    }
    if "FULCRUM_CERT_BUN_BIN" in environment:
        completeness_environment["FULCRUM_CERT_BUN_BIN"] = environment["FULCRUM_CERT_BUN_BIN"]
    command([str(attested / "shared-vault"), "--check-complete"], app,
            "native dispatch completeness", timeout=60, environment=completeness_environment)
    if {name: checked_native_binary(attested / name, binaries[name], single_link=True)
            for name in NATIVE_BINARIES} != entries:
        raise ReleaseError("native binary changed during completeness verification")
    return attested, entries


def write_runtime(staging: Path, version: str, revision: str,
                  bun_entry: tuple[str, int, int, str], native_attested: Path,
                  native_entries: dict[str, tuple[str, int, int, str]]) -> dict[str, tuple[str, int, int, str]]:
    expected = {"bin/bun": ("file", 0o755, bun_entry[2], bun_entry[3])}
    app = staging / "share" / "vault-services"
    binary = staging / "bin"
    binary.mkdir(parents=True)
    shutil.copyfile(app / "node_modules" / "bun" / "bin" / "bun.exe", binary / "bun")
    (binary / "bun").chmod(0o755)
    for name in NATIVE_BINARIES:
        target = binary / name
        shutil.copyfile(native_attested / name, target)
        target.chmod(0o755)
        expected[f"bin/{name}"] = checked_native_binary(target, native_entries[name][3], single_link=True)
    wrapper = binary / "vault-service"
    contents = ("#!/bin/sh\nset -eu\n"
                'script_dir=${0%/*}\nroot=$(CDPATH= cd -- "$script_dir/.." && pwd -P)\n'
                'exec "$root/bin/shared-vault" "$@"\n')
    wrapper.write_text(contents)
    wrapper.chmod(0o755)
    expected["bin/vault-service"] = ("file", 0o755, len(contents.encode()), hashlib.sha256(contents.encode()).hexdigest())
    for name, script in SCRIPTS.items():
        wrapper = binary / name
        contents = ("#!/bin/sh\nset -eu\n"
                           'script_dir=${0%/*}\nroot=$(CDPATH= cd -- "$script_dir/.." && pwd -P)\n'
                           f'exec "$root/bin/bun" --no-env-file "$root/share/vault-services/scripts/{script}" "$@"\n')
        wrapper.write_text(contents)
        wrapper.chmod(0o755)
        expected[f"bin/{name}"] = ("file", 0o755, len(contents.encode()), hashlib.sha256(contents.encode()).hexdigest())
    manifest = app / "release.json"
    if manifest.exists():
        raise ReleaseError("tracked source already owns the generated release manifest")
    contents = json.dumps({"packageVersion": version,
                                    "source": {"kind": "artifact", "revision": revision}},
                                   sort_keys=True, separators=(",", ":")) + "\n"
    manifest.write_text(contents)
    manifest.chmod(0o644)
    expected["share/vault-services/release.json"] = ("file", 0o644, len(contents.encode()), hashlib.sha256(contents.encode()).hexdigest())
    return expected


@contextmanager
def staged_file(root: Path, name: str):
    descriptors = []
    try:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(directory)
        parts = PurePosixPath(name).parts
        for part in parts[:-1]:
            directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            descriptors.append(directory)
        source = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(source, "rb") as opened:
            if not stat.S_ISREG(os.fstat(opened.fileno()).st_mode):
                raise ReleaseError("staging contains an unsupported file")
            yield opened
    except OSError as error:
        raise ReleaseError("staging contains a missing or unsafe path") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def stream_digest(source) -> str:
    digest = hashlib.sha256()
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def staging_inventory(root: Path) -> dict[str, tuple[str, int, int, str]]:
    inventory = {}
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ReleaseError("staging root is not a real directory")
    paths = [root]
    while paths:
        path = paths.pop()
        name = path.relative_to(root).as_posix()
        if name != "." and not allowed_path(name):
            raise ReleaseError("staging contains a private or mutable path")
        info = path.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISDIR(info.st_mode):
            inventory[name] = ("directory", mode, 0, "")
            paths.extend(path.iterdir())
        elif stat.S_ISREG(info.st_mode):
            with staged_file(root, name) as source:
                before = os.fstat(source.fileno())
                digest = stream_digest(source)
                after = os.fstat(source.fileno())
            identity = lambda value: (value.st_dev, value.st_ino, value.st_mode,
                                      value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            if identity(info) != identity(before) or identity(before) != identity(after):
                raise ReleaseError("staging changed during inventory")
            inventory[name] = ("file", mode, info.st_size, digest)
        else:
            raise ReleaseError("staging contains a link or unsupported file")
    return inventory


def certified_dependency_entries(root: Path, receipt_digest: str) -> dict[str, tuple[str, int, int, str]]:
    files = {name: entry for name, entry in staging_inventory(root).items() if entry[0] == "file"}
    digest = hashlib.sha256(INVENTORY_PREFIX)
    for name, entry in sorted(files.items(), key=lambda item: item[0].encode("utf-8")):
        encoded = name.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(b"\1" if entry[1] & 0o111 else b"\0")
        digest.update(bytes.fromhex(entry[3]))
        if entry[1] != (0o755 if entry[1] & 0o111 else 0o644):
            raise ReleaseError("copied dependency mode is not canonical")
    if digest.hexdigest() != receipt_digest:
        raise ReleaseError("copied dependency bytes differ from certification")
    return files


def authenticated_staging(root: Path, files: dict[str, tuple[str, int, int, str]]) -> dict[str, tuple[str, int, int, str]]:
    expected = dict(files)
    for name in files:
        for parent in PurePosixPath(name).parents:
            key = str(parent)
            if key in files:
                raise ReleaseError("approved staging paths conflict")
            expected[key] = ("directory", 0o755, 0, "")
    observed = staging_inventory(root)
    # Archive directories always have mode 0755. Keep actual modes in the seal
    # for later mutation checks, while authenticating their exact path/type set.
    canonical = {name: ("directory", 0o755, 0, "") if entry[0] == "directory" else entry
                 for name, entry in observed.items()}
    if canonical != expected:
        raise ReleaseError("staging differs from authenticated source, dependencies or runtime files")
    return observed


def verify_archive(output: Path, expected: dict[str, tuple[str, int, int, str]]) -> None:
    remaining = dict(expected)
    with tarfile.open(output, "r:gz") as archive:
        for member in archive:
            if member.name == ROOT_NAME:
                name = "."
            elif member.name.startswith(ROOT_NAME + "/"):
                name = member.name[len(ROOT_NAME) + 1:]
            else:
                raise ReleaseError("archive contains an unexpected path")
            entry = remaining.pop(name, None)
            if entry is None:
                raise ReleaseError("archive contains an unexpected or duplicate entry")
            kind, mode, size, digest = entry
            archived_mode = 0o755 if kind == "directory" or mode & 0o111 else 0o644
            if member.mode != archived_mode or member.size != size:
                raise ReleaseError("archive mode or size differs from approved staging")
            if kind == "directory":
                if not member.isdir():
                    raise ReleaseError("archive directory changed type")
            elif not member.isfile():
                raise ReleaseError("archive file changed type")
            else:
                with archive.extractfile(member) as source:
                    if stream_digest(source) != digest:
                        raise ReleaseError("archive bytes differ from approved staging")
    if remaining:
        raise ReleaseError("archive is missing approved entries")


def deterministic_archive(staging: Path, output: Path,
                          expected: dict[str, tuple[str, int, int, str]]) -> None:
    root = staging / ROOT_NAME
    if staging_inventory(root) != expected:
        raise ReleaseError("staged files changed before archive construction")
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=6) as zipped:
            with tarfile.open(fileobj=zipped, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                for name, (kind, mode, size, _) in sorted(expected.items()):
                    relative = ROOT_NAME if name == "." else f"{ROOT_NAME}/{name}"
                    info = tarfile.TarInfo(relative + ("/" if kind == "directory" else ""))
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ""
                    if kind == "directory":
                        info.type = tarfile.DIRTYPE
                        info.mode = 0o755
                        archive.addfile(info)
                    else:
                        info.size = size
                        info.mode = 0o755 if mode & 0o111 else 0o644
                        with staged_file(root, name) as source:
                            actual = os.fstat(source.fileno())
                            if stat.S_IMODE(actual.st_mode) != mode or actual.st_size != size:
                                raise ReleaseError("staged file changed during archive construction")
                            archive.addfile(info, source)
        raw.flush()
        os.fsync(raw.fileno())
    verify_archive(output, expected)


@contextmanager
def staging_directory(state: Path, run_id: str):
    path = Path(tempfile.mkdtemp(prefix=f"release-stage-{run_id}-", dir=state))
    settled = True
    try:
        yield path
    except UnsettledVerifier:
        settled = False
        raise
    finally:
        if settled:
            shutil.rmtree(path)


@contextmanager
def blocked_publication_signals():
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        yield previous
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def unlink_owned_link(link: Path, original: Path | None, identity: tuple[int, int] | None) -> None:
    try:
        actual = link.lstat()
    except FileNotFoundError:
        return
    if identity is None and original is not None:
        try:
            owned = original.lstat()
            identity = (owned.st_dev, owned.st_ino)
        except FileNotFoundError:
            return
    if stat.S_ISREG(actual.st_mode) and identity == (actual.st_dev, actual.st_ino):
        link.unlink()


def create_release(worktree: Path, receipt: Path, output: Path, state: Path) -> dict[str, str]:
    worktree, receipt, output, state = checked_paths(worktree, receipt, output, state)
    phase = "source"
    run_id = uuid.uuid4().hex
    archive_temp = None
    sidecar_temp = None
    archive_identity = None
    sidecar_identity = None
    staging_path = None
    try:
        revision = clean_revision(worktree)
        bun = worktree / "node_modules" / "bun" / "bin" / "bun.exe"
        phase = "certificate"
        version, receipt_sha, dependency_sha, native_hashes = certificate(worktree, receipt, bun, revision)
        phase = "dependencies"
        verify_dependencies(worktree, bun)
        if inventory_dependencies(worktree / "node_modules") != dependency_sha:
            raise ReleaseError("installed dependency bytes differ from certification")
        with staging_directory(state, run_id) as temporary:
            staging_path = temporary
            staging = temporary / ROOT_NAME
            app = staging / "share" / "vault-services"
            app.mkdir(parents=True)
            phase = "source-export"
            source_entries = export_tracked_source(worktree, revision, app)
            if json.loads((app / "package.json").read_text()).get("version") != version:
                raise ReleaseError("tracked package version changed")
            phase = "native-build"
            native_attested, native_entries = build_native(app, temporary, native_hashes)
            phase = "dependency-copy"
            copy_dependencies(worktree / "node_modules", app / "node_modules")
            dependency_entries = certified_dependency_entries(app / "node_modules", dependency_sha)
            runtime_entries = write_runtime(staging, version, revision,
                                            dependency_entries["bun/bin/bun.exe"], native_attested, native_entries)
            expected_files = {f"share/vault-services/{name}": entry for name, entry in source_entries.items()}
            expected_files.update({f"share/vault-services/node_modules/{name}": entry for name, entry in dependency_entries.items()})
            if expected_files.keys() & runtime_entries.keys():
                raise ReleaseError("generated runtime conflicts with certified inputs")
            expected_files.update(runtime_entries)
            sealed_files = authenticated_staging(staging, expected_files)
            phase = "staged-dependencies"
            verify_dependencies(app, staging / "bin" / "bun")
            if staging_inventory(staging) != sealed_files:
                raise ReleaseError("staged files changed during verification")
            phase = "source-stability"
            if clean_revision(worktree) != revision or inventory_dependencies(worktree / "node_modules") != dependency_sha:
                raise ReleaseError("source or dependency tree changed during packaging")
            checked_version, checked_receipt_sha, checked_dependency_sha, checked_native_hashes = certificate(worktree, receipt, bun, revision)
            if ((checked_version, checked_receipt_sha, checked_dependency_sha, checked_native_hashes)
                    != (version, receipt_sha, dependency_sha, native_hashes)):
                raise ReleaseError("certified source or receipt changed during packaging")
            if (clean_revision(worktree) != revision or file_digest(receipt) != receipt_sha
                    or inventory_dependencies(worktree / "node_modules") != dependency_sha):
                raise ReleaseError("certified source or receipt changed before archive construction")
            phase = "archive"
            fd, temporary_archive = tempfile.mkstemp(prefix=f"release-{run_id}-", suffix=".tar.gz", dir=state)
            os.close(fd)
            archive_temp = Path(temporary_archive)
            deterministic_archive(temporary, archive_temp, sealed_files)
            phase = "publish"
            verify_archive(archive_temp, sealed_files)
            hash_sri = "sha256-" + base64.b64encode(bytes.fromhex(file_digest(archive_temp))).decode()
            fd, temporary_sidecar = tempfile.mkstemp(prefix=f"release-hash-{run_id}-", dir=state)
            sidecar_temp = Path(temporary_sidecar)
            with os.fdopen(fd, "w") as target:
                target.write(hash_sri + "\n")
                target.flush()
                os.fsync(target.fileno())
            sidecar = output.with_name(output.name + ".sha256")
            with blocked_publication_signals():
                os.link(archive_temp, output)
                os.link(sidecar_temp, sidecar)
                directory = os.open(state, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
                archive_info = archive_temp.lstat()
                sidecar_info = sidecar_temp.lstat()
                archive_identity = (archive_info.st_dev, archive_info.st_ino)
                sidecar_identity = (sidecar_info.st_dev, sidecar_info.st_ino)
                archive_temp.unlink()
                sidecar_temp.unlink()
                archive_temp = sidecar_temp = None
        return {"status": "ready", "archive": str(output), "hash": hash_sri,
                "sourceRevision": revision, "packageVersion": version,
                "receiptSha256": receipt_sha, "installedDependenciesSha256": dependency_sha}
    except Exception as error:
        held = isinstance(error, UnsettledVerifier)
        with blocked_publication_signals():
            if not held:
                unlink_owned_link(output, archive_temp, archive_identity)
                unlink_owned_link(output.with_name(output.name + ".sha256"), sidecar_temp, sidecar_identity)
                if archive_temp is not None:
                    archive_temp.unlink(missing_ok=True)
                if sidecar_temp is not None:
                    sidecar_temp.unlink(missing_ok=True)
            diagnostic = state / f"failure-{run_id}.json"
            fd = os.open(diagnostic, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as target:
                target.write(json.dumps({"status": "held" if held else "failed", "phase": phase,
                                         "staging": str(staging_path) if held and staging_path else None,
                                         "supervisorPid": error.supervisor_pid if held else None,
                                         "reason": str(error) if isinstance(error, ReleaseError) else "unexpected packaging error"}) + "\n")
                target.flush()
                os.fsync(target.fileno())
        outcome = "held" if held else "failed"
        raise ReleaseError(f"release packaging {outcome} at {phase}; private diagnostic: {diagnostic}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worktree", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--state-directory", required=True, type=Path)
    args = parser.parse_args()
    def interrupt(_signal, _frame):
        raise ReleaseError("packaging interrupted")
    previous_int = signal.signal(signal.SIGINT, interrupt)
    previous_term = signal.signal(signal.SIGTERM, interrupt)
    try:
        print(json.dumps(create_release(args.worktree, args.receipt, args.output, args.state_directory), sort_keys=True))
        return 0
    except ReleaseError as error:
        print(str(error), file=sys.stderr)
        return 2
    except Exception:
        print("release packaging failed; inspect the private state directory", file=sys.stderr)
        return 2
    finally:
        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGTERM, previous_term)


if __name__ == "__main__":
    raise SystemExit(main())
