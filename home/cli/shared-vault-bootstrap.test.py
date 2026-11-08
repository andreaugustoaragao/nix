import base64
import hashlib
import importlib.util
import json
import os
import sys
import shutil
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

    def fixture(self, root):
        source = root / "source"
        source.mkdir()
        subprocess.run(["git", "init", "--quiet", str(source)], check=True)
        (source / ".gitignore").write_text("node_modules/\n.env\n")
        (source / ".env.example").write_text("EXAMPLE=placeholder\n")
        (source / "package.json").write_text('{"version":"1.2.3"}\n')
        subprocess.run(["git", "-C", str(source), "add", ".gitignore", ".env.example", "package.json"], check=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"], check=True)
        revision = bootstrap.git(source, "rev-parse", "HEAD").decode().strip()
        pin = {"sourceRevision": revision, "packageVersion": "1.2.3"}
        package = root / "package"
        app = package / "share/vault-services"
        (app / "node_modules").mkdir(parents=True)
        for name in [".gitignore", "package.json"]:
            (app / name).write_bytes((source / name).read_bytes())
        (app / "release.json").write_text(json.dumps({"packageVersion": "1.2.3", "source": {"kind": "artifact", "revision": revision}}))
        return source, package, pin

    def test_exact_git_checkout_and_nix_dependencies_are_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, package, pin = self.fixture(root)
            checkout = bootstrap.restore_checkout(str(source), root / "runtimes", package, pin)
            self.assertEqual(bootstrap.git(checkout, "rev-parse", "HEAD").decode().strip(), pin["sourceRevision"])
            self.assertEqual((checkout / "node_modules").resolve(), package / "share/vault-services/node_modules")
            self.assertEqual(bootstrap.restore_checkout(str(source), root / "runtimes", package, pin), checkout)
            (checkout / "package.json").write_text("local work")
            with self.assertRaisesRegex(bootstrap.RestoreError, "local changes"):
                bootstrap.restore_checkout(str(source), root / "runtimes", package, pin)
            self.assertEqual((checkout / "package.json").read_text(), "local work")

    def test_mismatched_package_preserves_existing_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, package, pin = self.fixture(root)
            (package / "share/vault-services/package.json").write_text("different certified bytes")
            with self.assertRaisesRegex(bootstrap.RestoreError, "bytes differ"):
                bootstrap.restore_checkout(str(source), root / "runtimes", package, pin)
            self.assertFalse((root / "runtimes" / pin["sourceRevision"]).exists())
            self.assertEqual(list((root / "runtimes").iterdir()), [])


    def test_ignored_dependency_overrides_and_environment_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, package, pin = self.fixture(root)
            checkout = bootstrap.restore_checkout(str(source), root / "runtimes", package, pin)
            nested = checkout / "src/node_modules/fixture-dependency/index.js"
            nested.parent.mkdir(parents=True)
            nested.write_text("module.exports = 'unapproved dependency'\n")
            self.assertEqual(bootstrap.git(checkout, "status", "--porcelain"), b"")
            with self.assertRaisesRegex(bootstrap.RestoreError, "unexpected directory"):
                bootstrap.restore_checkout(str(source), root / "runtimes", package, pin)
            self.assertTrue(nested.is_file())
            shutil.rmtree(checkout / "src")
            environment = checkout / ".env"
            environment.write_text("UNAPPROVED=fixture\n")
            with self.assertRaisesRegex(bootstrap.RestoreError, "unexpected file"):
                bootstrap.restore_checkout(str(source), root / "runtimes", package, pin)
            self.assertTrue(environment.is_file())

    def test_empty_destination_created_during_restore_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, package, pin = self.fixture(root)
            publish = bootstrap.publish_checkout
            identity = []
            def concurrent_directory(staging, target):
                target.mkdir(mode=0o700)
                identity.append(target.stat().st_ino)
                return publish(staging, target)
            with patch.object(bootstrap, "publish_checkout", side_effect=concurrent_directory):
                with self.assertRaises(FileExistsError):
                    bootstrap.restore_checkout(str(source), root / "runtimes", package, pin)
            target = root / "runtimes" / pin["sourceRevision"]
            self.assertEqual(target.stat().st_ino, identity[0])
            self.assertEqual(list(target.iterdir()), [])

    def test_embedded_source_credentials_are_rejected_before_git(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, package, pin = self.fixture(root)
            for repository in ["https://fixture:private-value@example.invalid/repo.git", "https://example.invalid/repo.git?token=private-value", "ssh://git:private-value@example.invalid/repo.git", "https::https://fixture:private-value@example.invalid/repo.git"]:
                with self.subTest(repository=repository), patch.object(bootstrap.subprocess, "run") as run:
                    with self.assertRaises(bootstrap.RestoreError) as error:
                        bootstrap.restore_checkout(repository, root / "runtimes", package, pin)
                    run.assert_not_called()
                    self.assertNotIn("private-value", str(error.exception))
            self.assertFalse((root / "runtimes").exists())


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
