#!/usr/bin/env python3
"""Controlled layout and refusal checks; the fake certificate is not release proof."""

import errno
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
import zlib
from unittest.mock import patch


SOURCE = Path(__file__).with_name("shared-vault-release.py")
SPEC = importlib.util.spec_from_file_location("shared_vault_release", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@unittest.skipUnless(sys.platform.startswith("linux"), "release supervision requires Linux")
class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="shared-vault-release-test-")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.state = self.private_state("state")
        self.receipt = self.base / "receipt.json"
        self.log = self.base / "bun-calls.jsonl"
        self.env_log = self.base / "bun-environments.jsonl"
        cache_home = self.private_state("fixture-cargo")
        for directory in ("cache", "index"):
            registry = cache_home / "registry" / directory / MODULE.CARGO_REGISTRY
            registry.mkdir(parents=True, mode=0o700)
            if directory == "index":
                (registry / ".cache").mkdir(mode=0o700)
        # Keep the real cache validation; individual cache tests override this default.
        cargo_environment = patch.dict(os.environ, {"CARGO_HOME": str(cache_home)})
        cargo_environment.start()
        self.addCleanup(cargo_environment.stop)

        files = {
            ".gitignore": "node_modules/\n",
            ".env.example": "SAMPLE=never-archive\n",
            "package.json": json.dumps({"version": "1.2.3", "packageManager": "bun@1.4.2"}) + "\n",
            "bun.lock": "{}\n",
            "Cargo.toml": "[workspace]\nmembers = ['services/shared-vault']\n",
            "Cargo.lock": "version = 4\n\n[[package]]\nname = 'shared-vault'\nversion = '0.1.0'\n",
            "services/shared-vault/Cargo.toml": "[package]\nname = 'shared-vault'\n",
            "services/shared-vault/flake.nix": "{ inputs.nixpkgs.url = 'github:NixOS/nixpkgs/4fe25e12eb9f4c744966dd3de5a05246cf098601'; }\n",
            "services/shared-vault/flake.lock": json.dumps({"nodes": {"nixpkgs": {"locked": {
                "rev": MODULE.SDK_REVISION, "narHash": MODULE.SDK_NAR_HASH}}}}) + "\n",
            "services/shared-vault/src/main.rs": "fn main() {}\n",
            "services/shared-vault/src/bin/shared-vault-grammar.rs": "fn main() {}\n",
            "services/shared-vault/helpers/document-extraction.ts": "// fixture\n",
            "scripts/development-certification.ts": "// fixture\n",
            "scripts/verify-installed-dependencies.ts": "// fixture\n",
            "scripts/verify-installed-patches.ts": "// fixture\n",
            "scripts/automation-runner-bootstrap.ts": "// fixture\n",
            "scripts/vault-service.ts": "// fixture\n",
            "scripts/vault.ts": "// fixture\n",
            "scripts/vault-mcp.ts": "// fixture\n",
            "src/dependency.ts": "export const fixture = true;\n",
        }
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        self.revision = self.git("rev-parse", "HEAD").stdout.strip()

        bun = self.repo / "node_modules/bun/bin/bun.exe"
        bun.parent.mkdir(parents=True)
        bun.write_text(f"#!{sys.executable}\n"
                       "import json,os,sys\n"
                       "a=sys.argv[1:]\n"
                       f"with open({str(self.log)!r},'a') as f:f.write(json.dumps(a)+'\\n')\n"
                       f"with open({str(self.env_log)!r},'a') as f:f.write(json.dumps({{'args':a,'env':{{k:v for k,v in os.environ.items() if k in ('LD_PRELOAD','LD_LIBRARY_PATH','NIX_LD','BUN_OPTIONS','NODE_OPTIONS','RUSTC_WRAPPER','CARGO_HOME','CC','PATH','HOME','GIT_CONFIG_GLOBAL','BUN_RUNTIME_TRANSPILER_CACHE_PATH','FULCRUM_CERT_BUN_BIN')}}}})+'\\n')\n"
                       "if a==['--version']:print('1.4.2')\n"
                       "elif len(a)>3 and a[:3]==['--no-env-file','scripts/development-certification.ts','check']:\n"
                       " r=json.load(open(a[4]));print(json.dumps({'status':'PASS','candidate':r['candidate'],'installedDependenciesSha256':r.get('installedDependenciesSha256'),'nativeArtifacts':r.get('nativeArtifacts')}))\n"
                       "elif len(a)>1 and a[0]=='--no-env-file' and 'verify-installed-' in a[1]:print('{\"ok\":true}')\n"
                       "elif len(a)>1 and a[0]=='--no-env-file':print(json.dumps(a[1:]))\n"
                       "else:sys.exit(2)\n")
        bun.chmod(0o755)
        package = self.repo / "node_modules/foo"
        package.mkdir()
        (package / "package.json").write_text('{"name":"foo","version":"1.0.0"}\n')
        (package / "index.js").write_text("export default 1;\n")
        links = self.repo / "node_modules/.bin"
        links.mkdir()
        (links / "foo").symlink_to("../foo/index.js")
        cache = self.repo / "node_modules/.cache"
        cache.mkdir()
        (cache / "mutable.txt").write_text("discard\n")
        self.write_receipt()

    def private_state(self, name):
        state = self.base / name
        state.mkdir(mode=0o700)
        return state

    def selected_bun_store(self):
        nix = self.base / "nix"
        store = nix / "store"
        selected = store / "certified-bun"
        selected.mkdir(parents=True)
        shutil.copyfile(self.repo / "node_modules/bun/bin/bun.exe", selected / "bun")
        (selected / "bun").chmod(0o555)
        for directory in (selected, store, nix):
            directory.chmod(0o555)
        self.addCleanup(lambda: [directory.chmod(0o755) for directory in (selected, store, nix)])
        return selected, store

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, text=True, capture_output=True, check=True)

    def write_receipt(self, **changes):
        content = {"schema": "fulcrum.certification.v1", "status": "PASS", "profile": "release",
                   "candidate": self.revision, "worktree": str(self.repo),
                   "installedDependenciesSha256": MODULE.inventory_dependencies(self.repo / "node_modules"),
                   "nativeArtifacts": {"schema": "fulcrum.shared-vault.native.v1",
                                       "candidate": self.revision, "target": MODULE.native_target()[0],
                                       "binaries": {name: hashlib.sha256(self.native_bytes(name)).hexdigest()
                                                    for name in MODULE.NATIVE_BINARIES}}}
        content.update(changes)
        self.receipt.write_text(json.dumps(content) + "\n")

    @staticmethod
    def native_bytes(name):
        header = bytearray(64)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<HH", header, 16, 2, MODULE.native_target()[1])
        return bytes(header) + name.encode()

    def fixture_command(self, args, cwd, phase, timeout=900, environment=None, build_paths=None):
        if phase == "certified native Cargo build":
            self.assertEqual(args[0], str(self.native_build_executable))
            self.assertIsNotNone(build_paths)
            flags = MODULE.native_build_path_flags(*build_paths)
            self.assertEqual({name: environment.get(name) for name in flags}, flags)
            self.assertEqual(environment["NOSYSBASHRC"], "1")
            self.assertEqual(args[args.index("--command") + 1:args.index("sh", args.index("--command"))],
                             ["env", "NOSYSBASHRC=1", *(f"{name}={value}" for name, value in flags.items())])
            target = Path(args[-4])
            for name in MODULE.NATIVE_BINARIES:
                binary = target / "release" / name
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(self.native_bytes(name))
                binary.chmod(0o755)
                deps = target / "release/deps" / name
                deps.parent.mkdir(parents=True, exist_ok=True)
                os.link(binary, deps)
            return b""
        if phase == "native dispatch completeness":
            self.assertEqual(Path(args[0]).parent.name, "native-attested")
            self.assertEqual(Path(args[0]).stat().st_nlink, 1)
            expected = {"PATH", "HOME", "TMPDIR", "LANG"}
            if "FULCRUM_CERT_BUN_BIN" in os.environ:
                expected.add("FULCRUM_CERT_BUN_BIN")
            self.assertEqual(set(environment), expected)
            return b""
        return self.real_command(args, cwd, phase, timeout=timeout, environment=environment,
                                 build_paths=build_paths)

    def create(self, state=None, name="release.tar.gz"):
        state = state or self.state
        output = state / name
        self.real_command = MODULE.command
        self.native_build_executable = Path(sys.executable).resolve(strict=True)
        self.assertTrue(str(self.native_build_executable).startswith("/nix/store/"))
        self.assertFalse(self.native_build_executable.stat().st_mode & 0o222)
        real_resolve = Path.resolve

        def fixture_resolve(path, strict=False):
            # Only the intercepted build's managed Nix lookup needs a stand-in.
            if path == Path("/run/current-system/sw/bin/nix"):
                self.assertTrue(strict)
                return self.native_build_executable
            return real_resolve(path, strict=strict)

        with patch.object(Path, "resolve", autospec=True, side_effect=fixture_resolve), \
                patch.object(MODULE, "command", side_effect=self.fixture_command):
            return MODULE.create_release(self.repo, self.receipt, output, state)

    def test_layout_and_determinism(self):
        first = self.create()
        other = self.private_state("other-state")
        second = self.create(other)
        self.assertEqual(first["hash"], second["hash"])
        self.assertEqual(first["installedDependenciesSha256"],
                         MODULE.inventory_dependencies(self.repo / "node_modules"))
        self.assertEqual((self.state / "release.tar.gz").read_bytes(), (other / "release.tar.gz").read_bytes())
        self.assertEqual((self.state / "release.tar.gz.sha256").read_text().strip(), first["hash"])
        with tarfile.open(self.state / "release.tar.gz", "r:gz") as archive:
            names = archive.getnames()
            self.assertTrue(all(name.startswith("shared-vault-release/") or name == "shared-vault-release" for name in names))
            self.assertFalse(any("/.git/" in name or name.endswith("/.git") or ".env" in name or ".cache" in name for name in names))
            self.assertFalse(any(member.issym() or member.islnk() for member in archive))
            self.assertIn("shared-vault-release/share/vault-services/src/dependency.ts", names)
            self.assertIn("shared-vault-release/share/vault-services/node_modules/.bin/foo", names)
            manifest = json.load(archive.extractfile("shared-vault-release/share/vault-services/release.json"))
            self.assertEqual(manifest, {"packageVersion": "1.2.3", "source": {"kind": "artifact", "revision": self.revision}})
            for name in ("bun", "vault-service", "shared-vault", "shared-vault-grammar", "vault-client", "vault-mcp"):
                self.assertIn(f"shared-vault-release/bin/{name}", names)
            service = archive.extractfile("shared-vault-release/bin/vault-service").read()
            self.assertIn(b'bin/shared-vault', service)
            self.assertNotIn(b'vault-service.ts', service)
            unpacked = self.base / "unpacked"
            unpacked.mkdir()
            archive.extractall(unpacked, filter="data")
        launcher = unpacked / "shared-vault-release/bin/vault-client"
        invoked = subprocess.run(["sh", str(launcher), "--probe"], text=True,
                                 capture_output=True, check=True)
        self.assertEqual(json.loads(invoked.stdout)[-1], "--probe")
        self.assertTrue(json.loads(invoked.stdout)[0].endswith("/scripts/vault.ts"))
        self.assertFalse(list(self.state.glob("release-stage-*")))
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(sum(call[1:3] == ["scripts/development-certification.ts", "check"] for call in calls), 4)
        self.assertTrue(any("verify-installed-dependencies.ts" in " ".join(call) for call in calls))
        self.assertTrue(any("verify-installed-patches.ts" in " ".join(call) for call in calls))

    def test_receipt_checker_and_dependency_verifiers_exclude_loader_overrides(self):
        rogue = self.base / "rogue-bin"
        rogue.mkdir()
        marker = self.base / "rogue-git-ran"
        (rogue / "git").write_text(f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(marker)!r}).write_text('ran')\n")
        (rogue / "git").chmod(0o755)
        injected = {
            "PATH": f"{rogue}:{os.environ['PATH']}",
            "LD_PRELOAD": str(self.base / "forged-loader.so"),
            "LD_LIBRARY_PATH": str(self.base / "forged-libraries"),
            "NIX_LD": str(self.base / "forged-interpreter"),
            "BUN_OPTIONS": "--preload=forged.ts",
            "NODE_OPTIONS": "--require=forged.js",
            "RUSTC_WRAPPER": str(self.base / "forged-rustc-wrapper"),
            "CC": str(self.base / "forged-cc"),
        }
        with patch.dict(os.environ, injected):
            self.create()
        calls = [json.loads(line) for line in self.env_log.read_text().splitlines()]
        checker = [call for call in calls if call["args"][1:3] == ["scripts/development-certification.ts", "check"]]
        dependencies = [call for call in calls if len(call["args"]) > 1 and "verify-installed-" in call["args"][1]]
        self.assertEqual(len(checker), 2)
        self.assertEqual(len(dependencies), 4)
        for call in checker + dependencies:
            with self.subTest(args=call["args"]):
                self.assertFalse((set(injected) - {"PATH"}) & set(call["env"]))
                self.assertNotIn(str(rogue), call["env"]["PATH"])
        self.assertFalse(marker.exists())

    def test_selected_store_bun_prefixes_managed_profiles_and_matches_project_pin(self):
        with patch.dict(os.environ, {key: value for key, value in os.environ.items()
                                    if key != "FULCRUM_CERT_BUN_BIN"}, clear=True):
            ordinary = MODULE.managed_path()
        selected, store = self.selected_bun_store()
        with patch.object(MODULE, "CERT_BUN_STORE_ROOT", store), patch.dict(os.environ, {
                "FULCRUM_CERT_BUN_BIN": str(selected)}):
            expected = f"{selected}:{ordinary}"
            self.assertEqual(MODULE.managed_path(), expected)
            self.create()
        calls = [json.loads(line) for line in self.env_log.read_text().splitlines()]
        checked = [call for call in calls if call["args"][1:3] == ["scripts/development-certification.ts", "check"]
                   or len(call["args"]) > 1 and "verify-installed-" in call["args"][1]]
        self.assertEqual(len(checked), 6)
        for call in checked:
            self.assertEqual(call["env"]["PATH"], expected)
            self.assertEqual(call["env"]["FULCRUM_CERT_BUN_BIN"], str(selected))

    def test_selected_store_bun_rejects_extra_git_before_verifiers(self):
        selected, store = self.selected_bun_store()
        marker = self.base / "rogue-git-ran"
        selected.chmod(0o755)
        rogue = selected / "git"
        rogue.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(marker)!r}).write_text('ran')\n")
        rogue.chmod(0o555)
        selected.chmod(0o555)
        with patch.object(MODULE, "CERT_BUN_STORE_ROOT", store), patch.dict(os.environ, {
                "FULCRUM_CERT_BUN_BIN": str(selected)}):
            with self.assertRaisesRegex(MODULE.ReleaseError, "release packaging failed at source") as failure:
                self.create()
            self.assertIn("only immutable executable bun", str(failure.exception.__cause__))
        self.assertFalse(marker.exists())
        self.assertFalse(self.log.exists())

    def test_selected_store_bun_rejects_symlinks_writable_inputs_and_nonstore_path(self):
        selected, store = self.selected_bun_store()
        binary = selected / "bun"
        with patch.object(MODULE, "CERT_BUN_STORE_ROOT", store):
            store.chmod(0o755)
            linked = store / "linked-bun"
            linked.symlink_to(selected, target_is_directory=True)
            store.chmod(0o555)
            with patch.dict(os.environ, {"FULCRUM_CERT_BUN_BIN": str(linked)}):
                with self.assertRaises(MODULE.ReleaseError):
                    MODULE.managed_path()

            selected.chmod(0o755)
            binary.unlink()
            binary.symlink_to(self.repo / "node_modules/bun/bin/bun.exe")
            selected.chmod(0o555)
            with patch.dict(os.environ, {"FULCRUM_CERT_BUN_BIN": str(selected)}):
                with self.assertRaises(MODULE.ReleaseError):
                    MODULE.managed_path()
            selected.chmod(0o755)
            binary.unlink()
            shutil.copyfile(self.repo / "node_modules/bun/bin/bun.exe", binary)
            binary.chmod(0o555)
            selected.chmod(0o555)

            for writable in (store.parent, store, selected, binary):
                writable.chmod(0o755)
                with patch.dict(os.environ, {"FULCRUM_CERT_BUN_BIN": str(selected)}):
                    with self.assertRaises(MODULE.ReleaseError):
                        MODULE.managed_path()
                writable.chmod(0o555)

            outside = self.base / "outside-bun"
            outside.mkdir()
            shutil.copyfile(binary, outside / "bun")
            (outside / "bun").chmod(0o555)
            outside.chmod(0o555)
            self.addCleanup(lambda: outside.chmod(0o755))
            with patch.dict(os.environ, {"FULCRUM_CERT_BUN_BIN": str(outside)}):
                with self.assertRaises(MODULE.ReleaseError):
                    MODULE.managed_path()

    def test_selected_store_bun_must_match_bytes_before_receipt_check(self):
        selected, store = self.selected_bun_store()
        binary = selected / "bun"
        binary.chmod(0o755)
        binary.write_bytes(binary.read_bytes() + b"changed")
        binary.chmod(0o555)
        with patch.object(MODULE, "CERT_BUN_STORE_ROOT", store), patch.dict(os.environ, {
                "FULCRUM_CERT_BUN_BIN": str(selected)}):
            with self.assertRaisesRegex(MODULE.ReleaseError, "release packaging failed at certificate") as failure:
                self.create()
            self.assertIn("differs from the project pin", str(failure.exception.__cause__))
            with self.assertRaisesRegex(MODULE.ReleaseError, "differs from the project pin"):
                MODULE.verify_dependencies(self.repo, self.repo / "node_modules/bun/bin/bun.exe")
        self.assertFalse(self.log.exists())

    def test_native_build_flags_remap_private_paths_and_quote_c_compiler_values(self):
        paths = [self.base / "source with ' quote", self.base / "cargo home", self.base / 'target "double"']
        for path in paths:
            path.mkdir()
        flags = MODULE.native_build_path_flags(*paths)
        destinations = ("/src/fulcrum", "/cargo-home", "/cargo-target")
        self.assertEqual(flags["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"),
                         [f"--remap-path-prefix={path}={destination}"
                          for path, destination in zip(paths, destinations)])
        expected_c = [f"-ffile-prefix-map={path}={destination}"
                      for path, destination in zip(paths, destinations)]
        self.assertEqual(shlex.split(flags["CFLAGS"]), expected_c)
        self.assertEqual(shlex.split(flags["CXXFLAGS"]), expected_c)
        self.assertEqual(flags["CC_SHELL_ESCAPED_FLAGS"], "1")
        for unsafe in (self.base / "bad=source", self.base / "bad\nsource"):
            unsafe.mkdir()
            with self.assertRaisesRegex(MODULE.ReleaseError, "canonical safe directory"):
                MODULE.native_build_path_flags(unsafe, paths[1], paths[2])

    def test_native_build_command_refuses_missing_or_changed_derived_flags(self):
        paths = [self.base / name for name in ("source", "cargo-home", "cargo-target")]
        for path in paths:
            path.mkdir()
        flags = MODULE.native_build_path_flags(*paths)
        environment = MODULE.managed_command_environment()
        environment.update(flags)
        environment["NOSYSBASHRC"] = "1"
        for changed in ({**environment, "CFLAGS": "-ffile-prefix-map=/rogue=/src/fulcrum"},
                        {key: value for key, value in environment.items() if key != "CXXFLAGS"},
                        {**environment, "CC_SHELL_ESCAPED_FLAGS": "0"},
                        {key: value for key, value in environment.items() if key != "CC_SHELL_ESCAPED_FLAGS"}):
            with self.assertRaisesRegex(MODULE.ReleaseError, "differ from the derived paths"):
                MODULE.command(["/bin/true"], self.repo, "certified native Cargo build",
                               environment=changed, build_paths=tuple(paths))

    def test_native_receipt_must_bind_exact_commit_target_and_binary_hashes(self):
        original = json.loads(self.receipt.read_text())
        cases = [
            None,
            {**original["nativeArtifacts"], "candidate": "0" * 40},
            {**original["nativeArtifacts"], "target": "aarch64-linux" if MODULE.native_target()[0] == "x86_64-linux" else "x86_64-linux"},
            {**original["nativeArtifacts"], "binaries": {"shared-vault": "0" * 64}},
            {**original["nativeArtifacts"], "binaries": {**original["nativeArtifacts"]["binaries"], "shared-vault": "0" * 64}},
        ]
        for evidence in cases:
            with self.subTest(evidence=evidence):
                self.write_receipt(nativeArtifacts=evidence)
                with self.assertRaises(MODULE.ReleaseError):
                    self.create(self.private_state("bad-native-" + str(cases.index(evidence))))
        self.assertFalse(list(self.base.glob("bad-native-*/release.tar.gz")))

    def test_missing_committed_native_source_is_refused(self):
        self.git("rm", "services/shared-vault/src/bin/shared-vault-grammar.rs")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "missing grammar")
        self.revision = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_receipt()
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())

    def test_native_build_rejects_missing_changed_linked_or_nonexecutable_outputs(self):
        original = self.fixture_command
        for kind in ("missing", "changed", "linked", "mode", "special"):
            with self.subTest(kind=kind):
                applied = []
                def faulty(args, cwd, phase, timeout=900, environment=None, build_paths=None):
                    result = original(args, cwd, phase, timeout, environment, build_paths)
                    if phase == "certified native Cargo build":
                        target = Path(args[-4])
                        binary = target / "release/shared-vault-grammar"
                        if kind == "missing":
                            binary.unlink()
                        elif kind == "changed":
                            binary.write_bytes(binary.read_bytes() + b"changed")
                        elif kind == "linked":
                            binary.unlink()
                            binary.symlink_to(target / "release/shared-vault")
                        elif kind == "special":
                            binary.chmod(0o1755)
                        else:
                            binary.chmod(0o644)
                        applied.append(kind)
                    return result
                with patch.object(self, "fixture_command", side_effect=faulty):
                    with self.assertRaisesRegex(MODULE.ReleaseError, "failed at native-build") as failure:
                        self.create(self.private_state("bad-build-" + kind))
                self.assertEqual(applied, [kind])
                cause = failure.exception.__cause__
                if kind == "missing":
                    self.assertIsInstance(cause, FileNotFoundError)
                elif kind == "linked":
                    self.assertIsInstance(cause, OSError)
                    self.assertEqual(cause.errno, errno.ELOOP)
                else:
                    self.assertIsInstance(cause, MODULE.ReleaseError)
                    self.assertIn("bytes differ" if kind == "changed" else "unexpected permissions", str(cause))
        self.assertFalse(list(self.base.glob("bad-build-*/release.tar.gz")))

    def test_incomplete_native_dispatch_cannot_be_packaged(self):
        original = self.fixture_command
        reached = []
        def incomplete(args, cwd, phase, timeout=900, environment=None, build_paths=None):
            result = original(args, cwd, phase, timeout, environment, build_paths)
            if phase == "native dispatch completeness":
                reached.append(phase)
                raise MODULE.ReleaseError("native dispatch incomplete")
            return result
        with patch.object(self, "fixture_command", side_effect=incomplete):
            with self.assertRaisesRegex(MODULE.ReleaseError, "failed at native-build") as failure:
                self.create()
        self.assertEqual(reached, ["native dispatch completeness"])
        self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
        self.assertEqual(str(failure.exception.__cause__), "native dispatch incomplete")
        self.assertFalse((self.state / "release.tar.gz").exists())

    def test_cargo_cache_is_lock_bound_and_ambient_build_overrides_are_excluded(self):
        cache_home = self.base / "ambient-cargo"
        cache = cache_home / "registry/cache" / MODULE.CARGO_REGISTRY
        index_root = cache_home / "registry/index" / MODULE.CARGO_REGISTRY / ".cache"
        cache.mkdir(parents=True)
        index_root.mkdir(parents=True)
        crate_bytes = b"verified crate archive bytes"
        checksum = hashlib.sha256(crate_bytes).hexdigest()
        crate = cache / "example-1.0.0.crate"
        crate.write_bytes(crate_bytes)
        index = index_root / MODULE.cargo_index_path("example")
        index.parent.mkdir(parents=True)
        record = {"name": "example", "vers": "1.0.0", "cksum": checksum, "deps": [], "features": {}}
        index.write_bytes(b'\x03\x02\0\0\0etag: "fixture"\0' + b"1.0.0\0"
                          + json.dumps(record).encode() + b"\0")
        index_bytes = index.read_bytes()
        (cache_home / "config.toml").write_text('[build]\nrustc-wrapper = "/tmp/external-wrapper"\n')
        (self.repo / "Cargo.lock").write_text(
            "version = 4\n\n[[package]]\nname = 'shared-vault'\nversion = '0.1.0'\n"
            f"\n[[package]]\nname = 'example'\nversion = '1.0.0'\nsource = '{MODULE.CARGO_SOURCE}'\nchecksum = '{checksum}'\n")
        (self.repo / ".cargo").mkdir()
        (self.repo / ".cargo/config.toml").write_text('[build]\nrustc-wrapper = "/tmp/source-wrapper"\n')
        self.git("add", "Cargo.lock", ".cargo/config.toml")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "locked crate fixture")
        self.revision = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_receipt()
        original = self.fixture_command
        inspected = []
        def inspect_build(args, cwd, phase, timeout=900, environment=None, build_paths=None):
            if phase == "certified native Cargo build":
                self.assertTrue(cwd.is_relative_to(self.state))
                self.assertFalse(cwd.is_relative_to(self.repo))
                self.assertEqual(Path(args[-1]), cwd)
                self.assertTrue(Path(args[-2]).is_absolute())
                self.assertNotIn("RUSTC_WRAPPER", environment)
                self.assertNotIn("CARGO_BUILD_RUSTC", environment)
                self.assertNotIn("CC", environment)
                self.assertEqual(environment["NIX_CONFIG"], "experimental-features = nix-command flakes\n")
                private_home = Path(args[-5])
                self.assertFalse((private_home / "config.toml").exists())
                self.assertEqual((private_home / "registry/cache" / MODULE.CARGO_REGISTRY / crate.name).read_bytes(), crate_bytes)
                inspected.append(phase)
            return original(args, cwd, phase, timeout, environment, build_paths)
        with patch.dict(os.environ, {"CARGO_HOME": str(cache_home), "RUSTC_WRAPPER": "/tmp/external-wrapper",
                                       "CARGO_BUILD_RUSTC": "/tmp/external-rustc", "CC": "/tmp/external-cc",
                                       "NIX_CONFIG": "substituters = https://invalid.example"}):
            with patch.object(self, "fixture_command", side_effect=inspect_build):
                self.create()
            self.assertEqual(inspected, ["certified native Cargo build"])
            crate.write_bytes(b"corrupt crate")
            with self.assertRaisesRegex(MODULE.ReleaseError, "failed at native-build") as failure:
                self.create(self.private_state("bad-crate"))
            self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
            self.assertIn("Cargo crate bytes differ", str(failure.exception.__cause__))
            crate.write_bytes(crate_bytes)
            index.write_bytes(index.read_bytes().replace(checksum.encode(), b"0" * 64))
            with self.assertRaisesRegex(MODULE.ReleaseError, "failed at native-build") as failure:
                self.create(self.private_state("bad-index"))
            self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
            self.assertIn("Cargo registry index differs", str(failure.exception.__cause__))
            index.write_bytes(index_bytes)
            moved = index.parent.with_name("relocated-index")
            index.parent.rename(moved)
            index.parent.symlink_to(moved)
            with self.assertRaisesRegex(MODULE.ReleaseError, "failed at native-build") as failure:
                self.create(self.private_state("linked-index"))
            self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
            self.assertIn("Cargo registry cache path is not canonical", str(failure.exception.__cause__))

    def test_ancestor_cargo_configuration_is_refused(self):
        ancestor = self.state / ".cargo"
        ancestor.mkdir()
        (ancestor / "config.toml").write_text('[build]\nrustc-wrapper = "/tmp/external-wrapper"\n')
        with self.assertRaisesRegex(MODULE.ReleaseError, "failed at native-build") as failure:
            self.create()
        self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
        self.assertIn("ancestor configuration override", str(failure.exception.__cause__))
        self.assertFalse((self.state / "release.tar.gz").exists())

    def test_export_helper_cannot_redefine_the_staging_baseline(self):
        remote = self.base / "promisor.git"
        subprocess.run(["git", "clone", "--bare", "--quiet", str(self.repo), str(remote)],
                       check=True, capture_output=True, timeout=20)
        helper = self.base / "local-upload-pack.py"
        marker = self.base / "export-helper-ran"
        upload_pack = shutil.which("git-upload-pack")
        self.assertIsNotNone(upload_pack)
        helper.write_text(f"#!{sys.executable}\n"
                          "import os,sys\nfrom pathlib import Path\n"
                          f"for stage in Path({str(self.state)!r}).glob('release-stage-*/shared-vault-release'):\n"
                          " app=stage/'share/vault-services'\n"
                          " target=app/'scripts/vault.ts'\n"
                          " if target.exists():\n"
                          "  target.write_text('UNCERTIFIED SOURCE\\n')\n"
                          "  (app/'src/injected.ts').write_text('UNTRACKED STAGING FILE\\n')\n"
                          f"  Path({str(marker)!r}).write_text('ran')\n"
                          f"os.execv({upload_pack!r},[{upload_pack!r},*sys.argv[1:]])\n")
        helper.chmod(0o700)
        self.git("remote", "add", "origin", str(remote))
        self.git("config", "remote.origin.promisor", "true")
        self.git("config", "remote.origin.partialclonefilter", "blob:none")
        self.git("config", "remote.origin.uploadpack", str(helper))
        missing = self.git("rev-parse", "HEAD:src/dependency.ts").stdout.strip()
        (self.repo / ".git/objects" / missing[:2] / missing[2:]).unlink()
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertTrue(marker.exists())
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.revision)
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertFalse((self.state / "release.tar.gz.sha256").exists())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def test_staged_verifiers_cannot_change_the_approved_archive(self):
        bun = self.repo / "node_modules/bun/bin/bun.exe"
        original_bun = bun.read_text()
        original_source = (self.repo / "src/dependency.ts").read_bytes()
        actions = {
            "source": "Path('src/dependency.ts').write_text('uncertified source\\n')",
            "mode": "Path('src/dependency.ts').chmod(0o755)",
            "private": "Path('.env').write_text('PROBE_ONLY=fixture\\n')",
            "runtime": "Path('../../bin/vault-client').write_text('changed wrapper\\n')",
            "removed": "Path('src/dependency.ts').unlink()",
            "directory-link": "shutil.rmtree('src'); Path('src').symlink_to(" + repr(str(self.repo / 'src')) + ")",
        }
        for name, action in actions.items():
            with self.subTest(name=name):
                marker = self.base / f"staged-{name}-applied"
                injected = ("a=sys.argv[1:]\nfrom pathlib import Path\nimport shutil\n"
                            f"if os.getcwd() != {str(self.repo)!r} and len(a)>1 and a[1]=='scripts/verify-installed-dependencies.ts':\n"
                            f" {action}\n Path({str(marker)!r}).write_text('applied')\n")
                bun.write_text(original_bun.replace("a=sys.argv[1:]\n", injected))
                self.write_receipt()
                state = self.private_state(f"staged-{name}")
                with self.assertRaisesRegex(MODULE.ReleaseError, "failed at staged-dependencies") as failure:
                    self.create(state)
                self.assertEqual(marker.read_text(), "applied")
                self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
                self.assertFalse((state / "release.tar.gz").exists())
                self.assertFalse((state / "release.tar.gz.sha256").exists())
                self.assertFalse(list(state.glob("release-stage-*")))
                self.assertEqual((self.repo / "src/dependency.ts").read_bytes(), original_source)

    def test_archive_reads_are_checked_against_the_sealed_files(self):
        original = MODULE.deterministic_archive
        applied = []

        def change_during_archive(staging, output, *args):
            source = staging / MODULE.ROOT_NAME / "share/vault-services/src/dependency.ts"
            source.write_bytes(source.read_bytes().replace(b"true", b"null"))
            applied.append("source")
            return original(staging, output, *args)

        with patch.object(MODULE, "deterministic_archive", side_effect=change_during_archive):
            with self.assertRaisesRegex(MODULE.ReleaseError, "failed at archive") as failure:
                self.create()
        self.assertEqual(applied, ["source"])
        self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
        self.assertIn("staged files changed before archive construction", str(failure.exception.__cause__))
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def test_emitted_archive_bytes_must_match_the_seal(self):
        original = tarfile.TarFile.addfile
        applied = []

        def changed_bytes(archive, info, source=None):
            if info.name.endswith("/src/dependency.ts"):
                source = io.BytesIO(source.read().replace(b"true", b"null"))
                applied.append(info.name)
            return original(archive, info, source)

        with patch.object(tarfile.TarFile, "addfile", new=changed_bytes):
            with self.assertRaisesRegex(MODULE.ReleaseError, "failed at archive") as failure:
                self.create()
        self.assertEqual(applied, [MODULE.ROOT_NAME + "/share/vault-services/src/dependency.ts"])
        self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
        self.assertIn("archive bytes differ from approved staging", str(failure.exception.__cause__))
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertFalse((self.state / "release.tar.gz.sha256").exists())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def test_existing_output_and_mismatched_receipt_are_refused(self):
        output = self.state / "release.tar.gz"
        output.write_bytes(b"existing")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertEqual(output.read_bytes(), b"existing")
        output.unlink()
        sidecar = self.state / "release.tar.gz.sha256"
        sidecar.write_text("existing\n")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertEqual(sidecar.read_text(), "existing\n")
        sidecar.unlink()
        self.write_receipt(candidate="a" * 40)
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.write_receipt(profile="core")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse(output.exists())
        self.assertEqual(len(list(self.state.glob("failure-*.json"))), 2)

    def test_dirty_source_and_departing_link_are_refused_and_staging_is_cleaned(self):
        (self.repo / "src/dependency.ts").write_text("dirty\n")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.git("checkout", "--", "src/dependency.ts")
        (self.repo / "node_modules/.bin/escape").symlink_to(self.base / "receipt.json")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse(list(self.state.glob("release-stage-*")))
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertEqual(len(list(self.state.glob("failure-*.json"))), 2)

    def test_tracked_environment_file_is_refused(self):
        (self.repo / ".env").write_text("PRIVATE=never-archive\n")
        self.git("add", ".env")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "private fixture")
        self.revision = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_receipt()
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def test_local_git_export_attributes_cannot_omit_committed_source(self):
        attributes = self.repo / ".git/info/attributes"
        attributes.write_text("src/dependency.ts export-ignore\nscripts/vault.ts export-subst\n")
        self.create()
        with tarfile.open(self.state / "release.tar.gz", "r:gz") as archive:
            source = archive.extractfile("shared-vault-release/share/vault-services/src/dependency.ts")
            self.assertEqual(source.read(), b"export const fixture = true;\n")

    def test_replacement_refs_cannot_substitute_the_candidate_tree(self):
        original = (self.repo / "src/dependency.ts").read_bytes()
        original_blob = self.git("rev-parse", "HEAD:src/dependency.ts").stdout.strip()
        (self.repo / "src/dependency.ts").write_text("export const fixture = 'replacement';\n")
        self.git("add", "src/dependency.ts")
        replacement_blob = self.git("hash-object", "src/dependency.ts").stdout.strip()
        tree = self.git("write-tree").stdout.strip()
        replacement = self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                               "commit-tree", tree, "-m", "replacement").stdout.strip()
        self.git("replace", self.revision, replacement)
        self.git("replace", original_blob, replacement_blob)
        self.git("reset", "--hard", "HEAD")
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all").stdout, "")
        destination = self.base / "raw-export"
        destination.mkdir()
        MODULE.export_tracked_source(self.repo, self.revision, destination)
        self.assertEqual((destination / "src/dependency.ts").read_bytes(), original)
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())

    def test_clean_filter_checkout_differing_from_raw_blob_is_refused(self):
        self.git("config", "filter.fixture.clean", "sed s/MATERIALIZED/COMMITTED/g")
        self.git("config", "filter.fixture.smudge", "sed s/COMMITTED/MATERIALIZED/g")
        (self.repo / ".gitattributes").write_text("src/dependency.ts filter=fixture\n")
        source = self.repo / "src/dependency.ts"
        source.write_text('export const fixture = "COMMITTED";\n')
        self.git("add", ".gitattributes", "src/dependency.ts")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "filtered fixture")
        self.revision = self.git("rev-parse", "HEAD").stdout.strip()
        source.unlink()
        self.git("checkout", "--", "src/dependency.ts")
        self.git("add", "src/dependency.ts")  # Refresh Git's filtered stat cache.
        self.assertIn("MATERIALIZED", source.read_text())
        self.assertIn("COMMITTED", self.git("show", "HEAD:src/dependency.ts").stdout)
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all").stdout, "")
        self.write_receipt()
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())

    def test_loose_blob_contents_must_match_the_requested_object_id(self):
        object_id = self.git("rev-parse", "HEAD:src/dependency.ts").stdout.strip()
        path = self.repo / ".git/objects" / object_id[:2] / object_id[2:]
        changed = b"export const fixture = false;\n"
        path.chmod(0o600)
        path.write_bytes(zlib.compress(f"blob {len(changed)}\0".encode() + changed))
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def test_commit_and_tree_contents_must_match_the_candidate_identity(self):
        original_tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        (self.repo / "src/dependency.ts").write_text("export const altered = true;\n")
        self.git("add", "src/dependency.ts")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "alternate tree")
        alternate = self.git("rev-parse", "HEAD").stdout.strip()
        alternate_tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.git("checkout", "-q", self.revision)
        for kind, original_id, alternate_id in [("tree", original_tree, alternate_tree), ("commit", self.revision, alternate)]:
            with self.subTest(kind=kind):
                path = self.repo / ".git/objects" / original_id[:2] / original_id[2:]
                original = path.read_bytes()
                path.chmod(0o600)
                replacement = subprocess.run(["git", "cat-file", kind, alternate_id], cwd=self.repo, check=True, capture_output=True).stdout
                try:
                    path.write_bytes(zlib.compress(f"{kind} {len(replacement)}\0".encode() + replacement))
                    self.git("read-tree", alternate)
                    (self.repo / "src/dependency.ts").write_text("export const altered = true;\n")
                    with self.assertRaises(MODULE.ReleaseError):
                        self.create(self.private_state(f"corrupt-{kind}"))
                finally:
                    path.write_bytes(original)
                    self.git("read-tree", self.revision)
                    self.git("checkout", "--", "src/dependency.ts")

    def test_final_git_hook_cannot_publish_changed_archive_bytes(self):
        hook = self.base / "final-git.py"
        marker = self.base / "final-git-ran"
        hook.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nimport sys\n"
                        f"for archive in Path({str(self.state)!r}).glob('release-*.tar.gz'):\n"
                        " archive.write_bytes(b'changed after archive verification')\n"
                        f" Path({str(marker)!r}).write_text('changed')\n"
                        "sys.stdout.buffer.write(b'fixture\\0/\\0')\n")
        hook.chmod(0o755)
        self.git("config", "core.fsmonitor", str(hook))
        result = self.create()
        self.assertEqual(result['status'], 'ready')
        self.assertFalse(marker.exists())
        with tarfile.open(self.state / "release.tar.gz", "r:gz") as archive:
            self.assertEqual(archive.extractfile(MODULE.ROOT_NAME + '/share/vault-services/src/dependency.ts').read(),
                             (self.repo / 'src/dependency.ts').read_bytes())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def test_hidden_executable_mode_change_is_refused(self):
        self.git("config", "core.filemode", "false")
        (self.repo / "src/dependency.ts").chmod(0o755)
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all").stdout, "")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())

    def test_excluded_link_target_and_changed_dependency_bytes_are_refused(self):
        cache_link = self.repo / "node_modules/.bin/cached"
        cache_link.symlink_to("../.cache/mutable.txt")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        cache_link.unlink()
        (self.repo / "node_modules/foo/index.js").write_text("changed after receipt\n")
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        (self.repo / "node_modules/foo/index.js").write_text("export default 1;\n")
        (self.repo / "node_modules/foo/index.js").chmod(0o755)
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def test_missing_dependency_digest_is_refused(self):
        self.write_receipt(installedDependenciesSha256=None)
        with self.assertRaises(MODULE.ReleaseError):
            self.create()
        self.assertFalse((self.state / "release.tar.gz").exists())

    def test_publication_failures_remove_only_owned_links(self):
        original = os.link
        for target_name in ("release.tar.gz", "release.tar.gz.sha256"):
            with self.subTest(target_name=target_name):
                applied = []
                def interrupted(source, destination):
                    original(source, destination)
                    if Path(destination).name == target_name:
                        applied.append(target_name)
                        raise MODULE.ReleaseError("packaging interrupted after publication link")
                with patch.object(MODULE.os, "link", side_effect=interrupted):
                    with self.assertRaisesRegex(MODULE.ReleaseError, "failed at publish") as failure:
                        self.create()
                self.assertEqual(applied, [target_name])
                self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
                self.assertEqual(str(failure.exception.__cause__), "packaging interrupted after publication link")
                self.assertFalse((self.state / "release.tar.gz").exists())
                self.assertFalse((self.state / "release.tar.gz.sha256").exists())
                self.assertFalse(list(self.state.glob("release-stage-*")))
                self.assertFalse(list(self.state.glob("release-hash-*")))

    def test_handled_signal_during_publication_cleans_both_links(self):
        original_link = os.link
        previous = signal.getsignal(signal.SIGTERM)
        applied = []
        def interrupted(_signal, _frame):
            raise MODULE.ReleaseError("packaging interrupted")
        def linked_then_signalled(source, destination):
            original_link(source, destination)
            if Path(destination).name == "release.tar.gz":
                applied.append("signal")
                signal.raise_signal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, interrupted)
        try:
            with patch.object(MODULE.os, "link", side_effect=linked_then_signalled):
                with self.assertRaisesRegex(MODULE.ReleaseError, "failed at publish") as failure:
                    self.create()
        finally:
            signal.signal(signal.SIGTERM, previous)
        self.assertEqual(applied, ["signal"])
        self.assertIsInstance(failure.exception.__cause__, MODULE.ReleaseError)
        self.assertEqual(str(failure.exception.__cause__), "packaging interrupted")
        self.assertFalse((self.state / "release.tar.gz").exists())
        self.assertFalse((self.state / "release.tar.gz.sha256").exists())
        self.assertFalse(list(self.state.glob("release-stage-*")))

    def detached_checker(self):
        marker = self.base / "detached-checker.json"
        program = (
            "import json,os,pathlib,subprocess,sys,time\n"
            "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],start_new_session=True)\n"
            "fields=pathlib.Path('/proc/'+str(child.pid)+'/stat').read_text().split(') ',1)[1].split()\n"
            "pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':child.pid,'startTime':fields[19]}))\n"
            "time.sleep(60)\n"
        )
        self.addCleanup(self.cleanup_detached_checker, marker)
        return [sys.executable, "-c", program, str(marker)], marker

    def cleanup_detached_checker(self, marker):
        if not marker.exists():
            return
        record = json.loads(marker.read_text())
        path = Path("/proc") / str(record["pid"]) / "stat"
        if path.exists():
            fields = path.read_text().split(") ", 1)[1].split()
            if fields[19] == record["startTime"]:
                os.kill(record["pid"], signal.SIGKILL)
                try:
                    os.waitpid(record["pid"], os.WNOHANG)
                except ChildProcessError:
                    pass

    def assert_detached_checker_joined(self, marker):
        record = json.loads(marker.read_text())
        path = Path("/proc") / str(record["pid"]) / "stat"
        if path.exists():
            fields = path.read_text().split(") ", 1)[1].split()
            self.assertNotEqual(fields[19], record["startTime"], "owned descendant still exists")

    def test_timeout_joins_detached_checker_descendant(self):
        args, marker = self.detached_checker()
        with self.assertRaises(MODULE.ReleaseError):
            MODULE.command(args, self.base, "fixture timeout", timeout=1)
        self.assertTrue(marker.exists())
        self.assert_detached_checker_joined(marker)

    def test_handled_interrupt_joins_detached_checker_descendant(self):
        args, marker = self.detached_checker()
        previous = signal.getsignal(signal.SIGTERM)
        trigger_program = (
            "import os,pathlib,sys,time\n"
            "marker=pathlib.Path(sys.argv[1]); parent=int(sys.argv[2])\n"
            "deadline=time.monotonic()+10\n"
            "while not marker.exists() and time.monotonic()<deadline:time.sleep(0.01)\n"
            "if marker.exists():os.kill(parent,15)\n"
        )
        def interrupted(_signal, _frame):
            raise MODULE.ReleaseError("fixture interrupted")

        signal.signal(signal.SIGTERM, interrupted)
        trigger = subprocess.Popen([sys.executable, "-c", trigger_program, str(marker), str(os.getpid())])
        try:
            with self.assertRaises(MODULE.ReleaseError):
                MODULE.command(args, self.base, "fixture interrupt", timeout=10)
        finally:
            if trigger.poll() is None:
                trigger.terminate()
            trigger.wait(timeout=10)
            signal.signal(signal.SIGTERM, previous)
        self.assertTrue(marker.exists())
        self.assert_detached_checker_joined(marker)

    def test_unsettled_verifier_retains_staging_for_recovery(self):
        original = MODULE.verify_dependencies
        reached = []

        def unsettled(root, bun):
            if "release-stage-" in str(root):
                reached.append(str(root))
                raise MODULE.UnsettledVerifier("fixture closure unproved", 999999)
            return original(root, bun)

        with patch.object(MODULE, "verify_dependencies", side_effect=unsettled):
            with self.assertRaisesRegex(MODULE.ReleaseError, "held at staged-dependencies") as failure:
                self.create()
        self.assertEqual(len(reached), 1)
        self.assertIsInstance(failure.exception.__cause__, MODULE.UnsettledVerifier)
        stages = list(self.state.glob("release-stage-*"))
        self.assertEqual(len(stages), 1)
        self.addCleanup(shutil.rmtree, stages[0])
        diagnostic = json.loads(next(self.state.glob("failure-*.json")).read_text())
        self.assertEqual(diagnostic["status"], "held")
        self.assertEqual(diagnostic["staging"], str(stages[0]))
        self.assertEqual(diagnostic["supervisorPid"], 999999)
        self.assertFalse((self.state / "release.tar.gz").exists())


class NativeSelectionFixture(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("readelf"),
                         "native ELF selection requires Linux readelf")
    def test_target_and_bun_are_retained_while_foreign_and_musl_are_pruned(self):
        evaluated = os.environ.get("SHARED_VAULT_NATIVE_INSTALL_PHASE")
        source = Path(evaluated) if evaluated else SOURCE.parents[2] / "pkgs/shared-vault-release.nix"
        match = re.search(r"python3 - .* <<'PY'\n(?P<body>.*?)\n[ \t]*PY(?=\n|$)",
                          source.read_text(), re.S)
        self.assertIsNotNone(match)
        script = match.group("body") if evaluated else textwrap.dedent(match.group("body"))
        target_machine = int(os.environ.get("SHARED_VAULT_NATIVE_TARGET", "62"))
        foreign_machine = 183 if target_machine == 62 else 62
        with tempfile.TemporaryDirectory(prefix="shared-vault-native-test-") as scratch:
            base = Path(scratch)
            root = base / "node_modules"
            bun = base / "bin/bun"
            pinned = root / "bun/bin/bun.exe"
            selected = root / "native/linux-target/module.node"
            foreign = root / "native/linux-foreign/module.node"
            musl = root / "native/linuxmusl-target/module.node"
            ordinary = root / "foo/index.js"

            def elf(machine):
                header = bytearray(64)
                header[:16] = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
                struct.pack_into("<HHIQQQIHHHHHH", header, 16,
                                 2, machine, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
                return bytes(header)

            for path, content in ((bun, elf(target_machine)), (pinned, elf(target_machine)),
                                  (selected, elf(target_machine)), (foreign, elf(foreign_machine)),
                                  (musl, elf(target_machine)), (ordinary, b"export default 1;\n")):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            result = subprocess.run([sys.executable, "-c", script, str(root), str(bun), str(target_machine)],
                                    text=True, capture_output=True, check=True)
            self.assertIn("retained=2 pruned=2", result.stdout)
            for path in (bun, pinned, selected, ordinary):
                self.assertTrue(path.is_file(), str(path))
            for path in (foreign, musl):
                self.assertFalse(path.exists(), str(path))


if __name__ == "__main__":
    unittest.main()
