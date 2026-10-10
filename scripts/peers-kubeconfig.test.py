"""Regression tests for the cluster-to-desktop credential import boundary."""

import base64
import copy
import importlib.util
import json
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "peers_kubeconfig", Path(__file__).with_name("peers-kubeconfig.py")
)
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class KubeconfigImportTests(unittest.TestCase):
    def setUp(self):
        blob = base64.b64encode(
            b"synthetic certificate data for structural tests"
        ).decode()
        self.config = {
            "apiVersion": "v1",
            "kind": "Config",
            "clusters": [
                {
                    "name": "remote",
                    "cluster": {
                        "server": "https://remote.example:6443",
                        "certificate-authority-data": blob,
                    },
                }
            ],
            "users": [
                {
                    "name": "remote",
                    "user": {
                        "client-certificate-data": blob,
                        "client-key-data": blob,
                    },
                }
            ],
            "contexts": [
                {"name": "remote", "context": {"cluster": "remote", "user": "remote"}}
            ],
            "current-context": "remote",
        }

    def sanitize(self):
        return importer.sanitize(
            json.dumps(self.config).encode(), "local", "https://10.211.55.5:6443"
        )

    def test_uses_local_endpoint_and_only_minimal_fields(self):
        cluster = self.config["clusters"][0]["cluster"]
        cluster.update(
            {
                "proxy-url": "http://remote.example",
                "insecure-skip-tls-verify": True,
                "tls-server-name": "remote.example",
                "certificate-authority": "/etc/passwd",
            }
        )
        self.config["contexts"][0]["context"]["namespace"] = "remote-choice"
        self.config["extensions"] = [{"name": "remote-plugin"}]
        result = self.sanitize()
        self.assertEqual(
            result["clusters"],
            [
                {
                    "name": "local",
                    "cluster": {
                        "server": "https://10.211.55.5:6443",
                        "certificate-authority-data": cluster[
                            "certificate-authority-data"
                        ],
                    },
                }
            ],
        )
        self.assertEqual(
            set(result),
            {"apiVersion", "kind", "clusters", "users", "contexts", "current-context"},
        )
        self.assertEqual(
            result["contexts"],
            [{"name": "local", "context": {"cluster": "local", "user": "local"}}],
        )

    def test_rejects_executable_plugins_and_local_credential_paths(self):
        for field, value in [
            ("exec", {"command": "/bin/sh", "args": ["-c", "echo unsafe"]}),
            ("auth-provider", {"name": "gcp", "config": {"cmd-path": "/bin/sh"}}),
            ("client-key", "/home/user/.ssh/id_ed25519"),
            ("client-certificate", "/home/user/private.pem"),
            ("tokenFile", "/home/user/.aws/credentials"),
        ]:
            with self.subTest(field=field):
                self.config["users"][0]["user"][field] = value
                with self.assertRaises(importer.InvalidConfig):
                    self.sanitize()
                del self.config["users"][0]["user"][field]

    def test_rejects_missing_and_malformed_embedded_credentials(self):
        for invalid in [None, "", "not base64", {"path": "/etc/passwd"}]:
            with self.subTest(value=invalid):
                self.config["users"][0]["user"]["client-key-data"] = invalid
                with self.assertRaises(importer.InvalidConfig):
                    self.sanitize()

    def test_rejects_ambiguous_contexts(self):
        self.config["contexts"].append(copy.deepcopy(self.config["contexts"][0]))
        with self.assertRaises(importer.InvalidConfig):
            self.sanitize()

    def test_rejects_yaml_object_constructors_and_oversize_input(self):
        for raw in [
            b"!!python/object/apply:builtins.print ['unsafe']",
            b"x" * (importer.MAX_BYTES + 1),
        ]:
            with self.assertRaises(importer.InvalidConfig):
                importer.sanitize(raw, "local", "https://10.211.55.5:6443")


if __name__ == "__main__":
    unittest.main()
