import base64
import hashlib
import importlib.util
import io
from types import SimpleNamespace
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.request

spec = importlib.util.spec_from_file_location("bootstrap", Path(__file__).with_name("shared-vault-bootstrap.py"))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class RestoreTests(unittest.TestCase):
    def test_wrong_archive_never_reaches_nix(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / bootstrap.ARCHIVE_NAME
            archive.write_bytes(b"changed archive")
            pin = {"hash": "sha256-" + base64.b64encode(hashlib.sha256(b"certified archive").digest()).decode()}
            with patch.object(bootstrap.subprocess, "run") as run:
                with self.assertRaisesRegex(bootstrap.RestoreError, "SHA256"):
                    bootstrap.import_archive(pin, archive)
                run.assert_not_called()

    def test_redirect_does_not_forward_credentials(self):
        request = urllib.request.Request("https://api.github.com/repos/andrearagao/fulcrum/releases/assets/1", headers={"Authorization": "Bearer fixture"})
        redirected = bootstrap.AssetRedirect().redirect_request(request, None, 302, "Found", {}, "https://release-assets.githubusercontent.com/asset")
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaises(bootstrap.RestoreError):
            bootstrap.AssetRedirect().redirect_request(request, None, 302, "Found", {}, "http://example.com/asset")

    def test_source_redirect_strips_credentials_and_refuses_other_hosts(self):
        request = urllib.request.Request("https://api.github.com/repos/andrearagao/fulcrum/tarball/revision", headers={"Authorization": "Bearer fixture"})
        redirected = bootstrap.SourceRedirect().redirect_request(request, None, 302, "Found", {}, "https://codeload.github.com/andrearagao/fulcrum/tar.gz/revision")
        self.assertIsNone(redirected.get_header("Authorization"))
        for url in ["https://example.invalid/source", "http://codeload.github.com/source", "https://fixture:secret@codeload.github.com/source"]:
            with self.subTest(url=url), self.assertRaises(bootstrap.RestoreError):
                bootstrap.SourceRedirect().redirect_request(request, None, 302, "Found", {}, url)

    def test_desktop_pin_requires_revision_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pin.json"
            pin = {"revision": "1" * 40, "hash": "sha256-" + base64.b64encode(bytes(32)).decode()}
            path.write_text(json.dumps(pin))
            self.assertEqual(bootstrap.read_desktop_pin(path), pin)
            for invalid in [None, [], {**pin, "hash": 3}, {**pin, "revision": 3}, {"revision": "1" * 40}, {**pin, "revision": "short"}, {**pin, "hash": "wrong"}]:
                path.write_text(json.dumps(invalid))
                with self.assertRaises(bootstrap.RestoreError):
                    bootstrap.read_desktop_pin(path)

    def test_source_download_size_is_bounded_before_import(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "source.tar.gz"
            opener = SimpleNamespace(open=lambda *args, **kwargs: io.BytesIO(b"too large"))
            with patch.object(bootstrap, "MAX_SOURCE_BYTES", 3), patch.object(bootstrap, "github_token", return_value="fixture"), patch.object(bootstrap.urllib.request, "build_opener", return_value=opener), patch.object(bootstrap.subprocess, "run") as run:
                with self.assertRaisesRegex(bootstrap.RestoreError, "exceeds"):
                    bootstrap.download_desktop({"revision": "1" * 40}, archive)
                run.assert_not_called()

    def test_desktop_import_requires_the_pinned_unpacked_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "source.tar.gz"
            archive.write_bytes(b"fixture archive")
            pin = {"hash": "sha256-" + base64.b64encode(bytes(32)).decode()}
            result = subprocess.CompletedProcess([], 0, "fixture-hash\n/nix/store/fixture-source\n")
            with patch.object(bootstrap.subprocess, "run", return_value=result) as run:
                self.assertEqual(bootstrap.import_desktop_archive(pin, archive), "/nix/store/fixture-source")
                args = run.call_args.args[0]
                self.assertEqual(args[-2:], [archive.resolve().as_uri(), pin["hash"]])
                self.assertIn(bootstrap.DESKTOP_SOURCE_NAME, args)

    def test_package_identity_is_verified_without_a_git_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            root = package / "share/vault-services"
            root.mkdir(parents=True)
            pin = {"sourceRevision": "1" * 40, "packageVersion": "1.2.3"}
            manifest = {"packageVersion": "1.2.3", "source": {"kind": "artifact", "revision": pin["sourceRevision"]}}
            (root / "release.json").write_text(json.dumps(manifest))
            (root / "package.json").write_text('{"version":"1.2.3"}')
            self.assertEqual(bootstrap.verify_package(package, pin), root)
            self.assertFalse((root / ".git").exists())
            (root / "package.json").write_text('{"version":"1.2.4"}')
            with self.assertRaisesRegex(bootstrap.RestoreError, "identity"):
                bootstrap.verify_package(package, pin)
            (root / "package.json").write_text('{"version":"1.2.3"}')
            manifest["source"]["revision"] = "2" * 40
            (root / "release.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(bootstrap.RestoreError, "identity"):
                bootstrap.verify_package(package, pin)

    def test_malformed_github_token_never_appears_in_cli_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            pin = Path(directory) / "pin.json"
            pin.write_text(json.dumps({
                "sourceRevision": "1" * 40, "packageVersion": "1.2.3",
                "hash": "sha256-" + base64.b64encode(hashlib.sha256(b"fixture").digest()).decode(),
                "url": "https://github.com/andrearagao/fulcrum/releases/download/test/shared-vault-release.tar.gz",
            }))
            secret = "fixture-secret-that-must-not-appear"
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("shared-vault-bootstrap.py")), "--pin", str(pin), "--archive-only"],
                                    env={**os.environ, "GH_TOKEN": secret + "\n"}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Invalid GitHub credential format", result.stderr)
            self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
