#!/usr/bin/env python3
"""Unit tests for home/cli/omp-configure.py."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import yaml

SPEC = importlib.util.spec_from_file_location(
    "omp_configure", Path(__file__).with_name("omp-configure.py")
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class OmpConfigureTest(unittest.TestCase):
    def test_preserves_unmanaged_and_user_overrides_until_nix_changes(self):
        desired = {
            "modelRoles": {
                "default": "litellm/gemini-4-hydrogen:high",
                "smol": "litellm/gemini-3.8-flash:medium",
            },
            "tui": {"vimMode": True},
            "retry": {"fallbackChains": {"default": ["litellm/gpt-6.2-sol:high"]}},
        }
        existing = {
            "modelRoles": {"default": "litellm/gemini-4-hydrogen:high"},
            "setupVersion": 3,
        }

        cfg1, rec1 = MOD.reconcile_config(desired, existing, {})
        self.assertEqual(cfg1["setupVersion"], 3)
        self.assertEqual(cfg1["modelRoles"]["smol"], "litellm/gemini-3.8-flash:medium")
        self.assertTrue(cfg1["tui"]["vimMode"])

        # User tweaks default model and disables vimMode via /settings
        user_edited = dict(cfg1)
        user_edited["modelRoles"] = dict(cfg1["modelRoles"])
        user_edited["modelRoles"]["default"] = "litellm/gpt-6.2-sol:high"
        user_edited["tui"] = {"vimMode": False}

        # Re-running with same desired Nix config preserves user's runtime edits
        cfg2, rec2 = MOD.reconcile_config(desired, user_edited, rec1)
        self.assertEqual(cfg2["modelRoles"]["default"], "litellm/gpt-6.2-sol:high")
        self.assertFalse(cfg2["tui"]["vimMode"])

        # Changing a value in Nix updates only the changed key
        desired_v2 = {
            "modelRoles": {
                "default": "litellm/gemini-4-hydrogen:high",
                "smol": "cursor/gemini-3.8-flash:medium",
            },
            "tui": {"vimMode": True},
        }
        cfg3, rec3 = MOD.reconcile_config(desired_v2, cfg2, rec2)
        self.assertEqual(cfg3["modelRoles"]["default"], "litellm/gpt-6.2-sol:high")
        self.assertEqual(cfg3["modelRoles"]["smol"], "cursor/gemini-3.8-flash:medium")
        self.assertFalse(cfg3["tui"]["vimMode"])
        # retry.fallbackChains.default was unchanged by user and removed from desired_v2 -> pruned
        self.assertNotIn("retry", cfg3)
        self.assertNotIn(MOD.encode_path(("retry", "fallbackChains", "default")), rec3)

    def test_mcp_merge_preserves_shared_vault_and_enabled_toggle(self):
        desired_mcp = {
            "nixos": {"type": "stdio", "command": "/nix/store/a-mcp-nixos/bin/mcp-nixos", "args": []},
            "context7": {"type": "http", "url": "https://mcp.context7.com/mcp"},
        }
        existing_mcp = {
            "mcpServers": {
                "shared_vault": {"type": "stdio", "command": "/nix/store/sv/bin/vault-mcp", "args": []}
            }
        }

        mcp1, rec1 = MOD.reconcile_mcp(desired_mcp, existing_mcp, {})
        self.assertIn("shared_vault", mcp1["mcpServers"])
        self.assertIn("nixos", mcp1["mcpServers"])
        self.assertIn("$schema", mcp1)

        # User disables nixos via /mcp disable nixos
        mcp1["mcpServers"]["nixos"]["enabled"] = False
        # Store path updates on next Nix rebuild -> enabled: false is preserved
        desired_mcp_v2 = {
            "nixos": {"type": "stdio", "command": "/nix/store/b-mcp-nixos/bin/mcp-nixos", "args": []},
        }
        mcp2, _ = MOD.reconcile_mcp(desired_mcp_v2, mcp1, rec1)
        self.assertEqual(
            mcp2["mcpServers"]["nixos"],
            {
                "type": "stdio",
                "command": "/nix/store/b-mcp-nixos/bin/mcp-nixos",
                "args": [],
                "enabled": False,
            },
        )
        # context7 was removed from desired -> retired, while shared_vault remains
        self.assertNotIn("context7", mcp2["mcpServers"])
        self.assertIn("shared_vault", mcp2["mcpServers"])

    def test_end_to_end_cli_writes_private_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            desired_cfg = root / "desired-cfg.json"
            desired_mcp = root / "desired-mcp.json"
            cfg_file = root / "agent/config.yml"
            mcp_file = root / "agent/mcp.json"
            receipt_file = root / "state/receipt.json"

            desired_cfg.write_text(json.dumps({"tui": {"vimMode": True}}))
            desired_mcp.write_text(json.dumps({"nixos": {"type": "stdio", "command": "mcp-nixos", "args": []}}))

            import subprocess, sys
            res = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("omp-configure.py")),
                    "--desired-config", str(desired_cfg),
                    "--desired-mcp", str(desired_mcp),
                    "--config-file", str(cfg_file),
                    "--mcp-file", str(mcp_file),
                    "--receipt-file", str(receipt_file),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(yaml.safe_load(cfg_file.read_text())["tui"]["vimMode"], True)
            self.assertIn("nixos", json.loads(mcp_file.read_text())["mcpServers"])
            self.assertEqual(cfg_file.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
