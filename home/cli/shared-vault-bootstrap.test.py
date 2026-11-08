import base64
import hashlib
import importlib.util
import json
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
        (source / ".gitignore").write_text("node_modules/\n")
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


if __name__ == "__main__":
    unittest.main()
