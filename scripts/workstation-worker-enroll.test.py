import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

SPEC = importlib.util.spec_from_file_location(
    "enroll", Path(__file__).with_name("workstation-worker-enroll.py")
)
enroll = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(enroll)


class EnrollmentTest(unittest.TestCase):
    def test_rejects_plaintext_and_extra_recipients(self):
        bundle = {name: "plaintext-fixture" for name in enroll.SECRET_NAMES}
        bundle["sops"] = {"age": [{"recipient": "worker"}]}
        with self.assertRaisesRegex(ValueError, "must be encrypted"):
            enroll.check_bundle(yaml.safe_dump(bundle), ["worker"])
        bundle.update({name: "ENC[AES256_GCM,fixture]" for name in enroll.SECRET_NAMES})
        bundle["sops"]["pgp"] = [{"fp": "unexpected"}]
        with self.assertRaisesRegex(ValueError, "non-age"):
            enroll.check_bundle(yaml.safe_dump(bundle), ["worker"])

    def test_real_sops_bundle_is_minimal_idempotent_and_separately_encrypted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            keys = []
            for name in ("admin", "worker"):
                private = root / (name + ".key")
                subprocess.run(
                    ["age-keygen", "-o", str(private)], check=True, capture_output=True
                )
                keys.append(
                    subprocess.check_output(
                        ["age-keygen", "-y", str(private)], text=True
                    ).strip()
                )
            rules = f"keys:\n  - &admin_key {keys[0]}\ncreation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: *admin_key\n"
            (root / ".sops.yaml").write_text(rules)
            (root / "secrets").mkdir()
            selected = {name: "fixture-" + name for name in enroll.SECRET_NAMES}
            source = {**selected, "desktop_token": "never-copy-this-fixture"}
            cipher = subprocess.check_output(
                [
                    "sops",
                    "--encrypt",
                    "--config",
                    "/dev/null",
                    "--input-type",
                    "json",
                    "--output-type",
                    "yaml",
                    "--age",
                    keys[0],
                    "/dev/stdin",
                ],
                input=json.dumps(source).encode(),
                cwd=root,
            )
            (root / "secrets/secrets.yaml").write_bytes(cipher)
            public = {
                "age": keys[1],
                "ssh": "ssh-ed25519 "
                + base64.b64encode(
                    b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + b"h" * 32
                ).decode(),
                "cache": "workstation-worker-1:" + base64.b64encode(b"c" * 32).decode(),
            }
            old_environment = os.environ.get("SOPS_AGE_KEY_FILE")
            try:
                os.environ["SOPS_AGE_KEY_FILE"] = str(root / "admin.key")
                self.assertTrue(enroll.enroll(root, public)["enrolled"])
                worker = root / enroll.WORKER_FILE
                digest = hashlib.sha256(worker.read_bytes()).hexdigest()
                self.assertNotIn("never-copy-this-fixture", worker.read_text())
                result = json.loads(
                    subprocess.check_output(
                        ["sops", "--decrypt", "--output-type", "json", str(worker)],
                        env={
                            **os.environ,
                            "SOPS_AGE_KEY_FILE": str(root / "worker.key"),
                        },
                    )
                )
                self.assertEqual(result, selected)
                self.assertEqual((root / "secrets/secrets.yaml").read_bytes(), cipher)
                loaded = yaml.safe_load((root / ".sops.yaml").read_text())
                self.assertEqual(
                    loaded["creation_rules"][1],
                    yaml.safe_load(rules)["creation_rules"][0],
                )
                self.assertEqual(
                    loaded["creation_rules"][0]["key_groups"][0]["age"], keys
                )
                staged = subprocess.check_output(
                    ["git", "-C", str(root), "ls-files"], text=True
                ).splitlines()
                self.assertIn(enroll.WORKER_FILE, staged)
                enroll.enroll(root, public)
                self.assertEqual(
                    hashlib.sha256(worker.read_bytes()).hexdigest(), digest
                )
                with self.assertRaisesRegex(ValueError, "rotation"):
                    enroll.enroll(
                        root,
                        {
                            **public,
                            "cache": "workstation-worker-1:"
                            + base64.b64encode(b"x" * 32).decode(),
                        },
                    )
                self.assertEqual(
                    hashlib.sha256(worker.read_bytes()).hexdigest(), digest
                )
                runtime = root / "runtime-secrets"
                runtime.mkdir()
                runtime_values = {
                    name: "runtime-" + name for name in enroll.SECRET_NAMES
                }
                for name, value in runtime_values.items():
                    (runtime / name).write_text(value)
                worker.unlink()
                (root / "secrets/secrets.yaml").unlink()
                enroll.enroll(root, public, runtime)
                result = json.loads(
                    subprocess.check_output(
                        ["sops", "--decrypt", "--output-type", "json", str(worker)],
                        env={
                            **os.environ,
                            "SOPS_AGE_KEY_FILE": str(root / "worker.key"),
                        },
                    )
                )
                self.assertEqual(result, runtime_values)
            finally:
                if old_environment is None:
                    os.environ.pop("SOPS_AGE_KEY_FILE", None)
                else:
                    os.environ["SOPS_AGE_KEY_FILE"] = old_environment


if __name__ == "__main__":
    unittest.main()
