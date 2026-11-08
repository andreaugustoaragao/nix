import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("configure", Path(__file__).with_name("shared-vault-configure.py"))
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shared-vault-config-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.target = self.root / "config.json"
        self.client = {"kind": "claude", "target": str(self.target), "desired": self.entry("v1")}

    @staticmethod
    def entry(version):
        return {"command": f"/nix/store/{version}/bin/vault-mcp", "args": [], "env": {}}

    def write(self, value):
        self.target.write_text(json.dumps(value))

    def apply(self):
        return configure.reconcile(self.client, "shared-vault", self.state, "apply")

    def check(self):
        return configure.reconcile(self.client, "shared-vault", self.state)

    def current(self):
        return json.loads(self.target.read_text())

    def owned(self):
        return self.state / f"{self.client['kind']}.json"

    def test_all_mutable_native_formats_preserve_other_configuration(self):
        for kind in ("codex", "claude", "cursor", "pi"):
            with self.subTest(kind=kind):
                self.client["kind"] = kind
                if kind == "codex":
                    self.target.write_text('# keep this comment\nmodel="unchanged"\n[mcp_servers.other]\ncommand="other"\n[profiles.personal]\nmodel="private"\n')
                else:
                    self.write({"token": "sensitive-value", "hooks": {"other": []}, "weight": 0.75,
                                "mcpServers": {"other": {"command": "other"}}})
                before = configure.decode(configure.snapshot(self.target), kind)
                self.apply()
                after = configure.decode(configure.snapshot(self.target), kind)
                self.assertEqual(configure.entry(after, kind, "shared-vault"), self.client["desired"])
                (after["mcp_servers"] if kind == "codex" else after["mcpServers"]).pop("shared-vault")
                self.assertEqual(after, before)
                self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
                if kind == "codex":
                    self.assertIn("# keep this comment", self.target.read_text())
                self.target.unlink()

    def test_upgrade_replaces_only_owned_entry_and_retirement_converges(self):
        other = {"command": "unrelated", "env": {"SECRET": "do-not-emit"}}
        self.write({"mcpServers": {"other": other}, "identity": "unchanged"})
        self.apply()
        self.client["desired"] = {"command": "/nix/store/v2/bin/vault-mcp", "args": []}
        self.apply()
        self.assertEqual(self.current()["mcpServers"]["shared-vault"], self.client["desired"])
        self.client["desired"] = None
        self.assertEqual(self.apply(), "retired")
        self.assertEqual(self.current(), {"mcpServers": {"other": other}, "identity": "unchanged"})
        before = (self.target.read_bytes(), self.target.stat().st_mtime_ns, self.owned().read_bytes())
        self.assertEqual(self.apply(), "absent")
        self.assertEqual(before, (self.target.read_bytes(), self.target.stat().st_mtime_ns, self.owned().read_bytes()))

    def test_repeated_active_configuration_is_unchanged(self):
        self.apply()
        before = (self.target.stat().st_ino, self.owned().stat().st_ino)
        self.assertEqual(self.check(), "configured")
        self.assertEqual(self.apply(), "configured")
        self.assertEqual(before, (self.target.stat().st_ino, self.owned().stat().st_ino))

    def test_unowned_even_identical_entry_is_not_adopted(self):
        self.write({"mcpServers": {"shared-vault": self.client["desired"]}})
        before = self.target.read_bytes()
        with self.assertRaisesRegex(configure.Conflict, "unowned"):
            self.apply()
        self.assertEqual(self.target.read_bytes(), before)
        self.assertFalse(self.owned().exists())

    def test_manual_modification_is_preserved_during_upgrade_and_removal(self):
        self.apply()
        self.write({"mcpServers": {"shared-vault": self.entry("manual")}, "model": "user"})
        before = self.target.read_bytes()
        for desired in (self.entry("v2"), None):
            self.client["desired"] = desired
            with self.assertRaisesRegex(configure.Conflict, "modified"):
                self.apply()
            self.assertEqual(self.target.read_bytes(), before)

    def test_missing_owned_entry_can_be_restored(self):
        self.apply()
        self.write({"user": "still-present"})
        with self.assertRaisesRegex(configure.Conflict, "drift"):
            self.check()
        self.apply()
        self.assertEqual(self.current()["user"], "still-present")

    def test_interruption_before_or_after_publication_recovers_new_generation(self):
        real_write = configure.atomic_write
        for phase in ("before", "after"):
            with self.subTest(phase=phase):
                self.target.unlink(missing_ok=True)
                self.owned().unlink(missing_ok=True)
                self.client["desired"] = self.entry("v1")

                def interrupted(path, content, expected):
                    if path == self.target and phase == "before":
                        raise OSError("simulated crash before publication")
                    if path == self.owned() and self.target.exists() and phase == "after":
                        raise OSError("simulated crash after publication")
                    real_write(path, content, expected)

                with patch.object(configure, "atomic_write", interrupted), self.assertRaises(OSError):
                    self.apply()
                self.client["desired"] = self.entry("v2")
                self.apply()
                self.assertEqual(self.current()["mcpServers"]["shared-vault"], self.entry("v2"))
                self.assertEqual(json.loads(self.owned().read_text())["managed"], [self.entry("v2")])

    def test_interrupted_retirement_keeps_unrelated_data(self):
        self.write({"user": 123})
        self.apply()
        self.client["desired"] = None
        real_journal = configure.journal
        calls = 0

        def interrupted(*args):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("simulated crash")
            return real_journal(*args)

        with patch.object(configure, "journal", interrupted), self.assertRaises(OSError):
            self.apply()
        self.apply()
        self.assertEqual(self.current()["user"], 123)
        self.assertNotIn("shared-vault", self.current()["mcpServers"])

    def test_check_creates_no_files(self):
        self.state.rmdir()
        with self.assertRaisesRegex(configure.Conflict, "drift"):
            self.check()
        self.assertFalse(self.target.exists())
        self.assertFalse(self.state.exists())

    def test_prepare_allows_fresh_and_owned_upgrades_without_writing(self):
        self.state.rmdir()
        self.assertEqual(configure.reconcile(self.client, "shared-vault", self.state, "prepare"), "ready")
        self.assertFalse(self.state.exists())
        self.assertFalse(self.target.exists())
        self.apply()
        before = (self.target.read_bytes(), self.owned().read_bytes())
        self.client["desired"] = self.entry("v2")
        self.assertEqual(configure.reconcile(self.client, "shared-vault", self.state, "prepare"), "ready")
        self.assertEqual(before, (self.target.read_bytes(), self.owned().read_bytes()))
        self.apply()
        self.assertEqual(self.check(), "configured")

    def test_invalid_config_and_journal_preserve_bytes(self):
        for text in ('{"mcpServers":', '{"mcpServers": {}, "mcpServers": {}}', '{"mcpServers": []}', '[]'):
            self.target.write_text(text)
            with self.assertRaises(configure.Conflict):
                self.apply()
            self.assertEqual(self.target.read_text(), text)
        self.write({})
        self.owned().write_text('{"managed": []}')
        with self.assertRaisesRegex(configure.Conflict, "journal"):
            self.apply()
        self.assertEqual(self.current(), {})

    def test_journal_cannot_be_reused_for_another_target(self):
        self.apply()
        self.client["target"] = str(self.root / "different.json")
        with self.assertRaisesRegex(configure.Conflict, "journal"):
            self.apply()
        self.assertFalse(Path(self.client["target"]).exists())

    def test_symlinks_and_hardlinks_are_preserved(self):
        original = self.root / "original.json"
        original.write_text('{"private": true}')
        self.target.symlink_to(original)
        with self.assertRaises(configure.Conflict):
            self.apply()
        self.assertTrue(self.target.is_symlink())
        self.target.unlink()
        os.link(original, self.target)
        with self.assertRaises(configure.Conflict):
            self.apply()
        self.assertEqual(original.read_text(), '{"private": true}')

    def test_changed_input_is_not_replaced(self):
        self.write({"first": True})
        real_write = configure.atomic_write

        def changed(path, content, expected):
            if path == self.target:
                self.write({"external-change": True})
            real_write(path, content, expected)

        with patch.object(configure, "atomic_write", changed), self.assertRaisesRegex(configure.Conflict, "changed"):
            self.apply()
        self.assertEqual(self.current(), {"external-change": True})
        self.assertFalse(list(self.root.glob(".config.json.*")))

    def test_opencode_generated_link_is_read_only_and_conflicts_are_reported(self):
        original = self.root / "generated.jsonc"
        overlay = self.root / "opencode.json"
        original.write_text('// comment\n' + json.dumps({"mcp": {"servers": {"shared-vault": self.client["desired"]}}}))
        self.target.symlink_to(original)
        self.client.update(kind="opencode", overlay=str(overlay), generated=str(original))
        self.assertEqual(self.check(), "configured")
        overlay.write_text(json.dumps({"mcp": {"servers": {"shared-vault": self.entry("different")}}}))
        with self.assertRaisesRegex(configure.Conflict, "overlay"):
            self.apply()
        self.assertTrue(self.target.is_symlink())
        self.assertFalse(self.owned().exists())

    def test_opencode_retirement_detects_legacy_registration(self):
        overlay = self.root / "opencode.json"
        self.write({"mcp": {"servers": {}}})
        overlay.write_text(json.dumps({"mcp": {"shared-vault": self.entry("legacy")}}))
        self.client.update(kind="opencode", overlay=str(overlay), desired=None, generated=None)
        with self.assertRaisesRegex(configure.Conflict, "legacy"):
            self.check()
        self.assertIn("shared-vault", json.loads(overlay.read_text())["mcp"])

    def test_batch_reports_partial_state_without_configuration_values(self):
        self.write({"mcpServers": {"shared-vault": {"command": "PRIVATE-SENTINEL"}}})
        manifest_path = self.root / "manifest.json"
        pi = {"kind": "pi", "target": str(self.root / "pi.json"), "desired": self.entry("v1")}
        manifest_path.write_text(json.dumps({"version": 1, "name": "shared-vault", "clients": [self.client, pi]}))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = configure.run(argparse.Namespace(manifest=manifest_path, state_directory=self.state, apply=True, prepare=False))
        self.assertEqual(code, 2)
        self.assertNotIn("PRIVATE-SENTINEL", output.getvalue())
        results = json.loads(output.getvalue())["clients"]
        self.assertEqual([row["ok"] for row in results], [False, True])
        self.assertTrue(Path(pi["target"]).exists())

    def test_unsafe_state_directory_is_not_used(self):
        self.state.chmod(0o755)
        with self.assertRaisesRegex(configure.Conflict, "unsafe-state"):
            configure.private_directory(self.state)

    def test_prepare_receipt_precedes_publication_and_check_requires_settlement(self):
        path = self.root / "manifest.json"
        path.write_text(json.dumps({"version": 1, "name": "shared-vault", "clients": [self.client]}))

        def execute(mode):
            with contextlib.redirect_stdout(io.StringIO()):
                return configure.run(argparse.Namespace(manifest=path, state_directory=self.state,
                                                        apply=mode == "apply", prepare=mode == "prepare"))

        self.assertEqual(execute("prepare"), 0)
        self.assertFalse(self.target.exists())
        self.assertEqual(json.loads((self.state / "activation.json").read_text())["phase"], "prepared")
        self.assertEqual(execute("check"), 2)
        self.assertEqual(execute("apply"), 0)
        self.assertEqual(execute("check"), 0)
        self.assertEqual(json.loads((self.state / "activation.json").read_text())["phase"], "settled")

    def test_prepared_receipt_survives_loss_of_unflushed_directory_entries(self):
        path = self.root / "manifest.json"
        path.write_text(json.dumps({"version": 1, "name": "shared-vault", "clients": [self.client]}))
        flushed = set()
        real_fsync = os.fsync

        def fsync(descriptor):
            info = os.fstat(descriptor)
            if stat.S_ISDIR(info.st_mode):
                flushed.add((info.st_dev, info.st_ino))
            real_fsync(descriptor)

        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                storage = self.root / str(interrupted)
                namespace = storage / "shared-vault"
                receipts = namespace / "registrations"
                if interrupted:
                    receipts.mkdir(parents=True, mode=0o700)
                flushed.clear()
                with patch.object(os, "fsync", fsync), contextlib.redirect_stdout(io.StringIO()):
                    code = configure.run(argparse.Namespace(manifest=path, state_directory=receipts, apply=False, prepare=True))
                self.assertEqual(code, 0)
                for created in (storage, namespace, receipts):
                    parent = created.parent.stat()
                    if (parent.st_dev, parent.st_ino) not in flushed:
                        shutil.rmtree(created)
                        break
                self.assertTrue((receipts / "activation.json").exists(), "Host crash lost the acknowledged activation receipt")
                self.assertEqual(json.loads((receipts / "activation.json").read_text())["phase"], "prepared")

    def test_failed_ancestor_flush_cannot_acknowledge_preparation(self):
        path = self.root / "manifest.json"
        path.write_text(json.dumps({"version": 1, "name": "shared-vault", "clients": [self.client]}))
        ancestor = self.root.stat()
        real_fsync = os.fsync

        def fsync(descriptor):
            info = os.fstat(descriptor)
            if (info.st_dev, info.st_ino) == (ancestor.st_dev, ancestor.st_ino):
                raise OSError("injected ancestor flush failure")
            real_fsync(descriptor)

        output = io.StringIO()
        with patch.object(os, "fsync", fsync), contextlib.redirect_stdout(output):
            with self.assertRaises(OSError):
                configure.run(argparse.Namespace(manifest=path, state_directory=self.state, apply=False, prepare=True))
        self.assertEqual(output.getvalue(), "")
        self.assertFalse((self.state / "activation.json").exists())
        self.assertFalse(self.target.exists())

    def test_native_toml_value_in_manual_edit_reports_drift_without_traceback(self):
        self.client["kind"] = "codex"
        self.apply()
        with self.target.open("a") as output:
            output.write('last_seen = 2026-11-04T00:00:00Z\n')
        before = self.target.read_bytes()
        path = self.root / "manifest.json"
        other = {"kind": "pi", "target": str(self.root / "pi.json"), "desired": None}
        path.write_text(json.dumps({"version": 1, "name": "shared-vault", "clients": [self.client, other]}))
        state_before = {item.name: item.read_bytes() for item in self.state.iterdir()}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = configure.run(argparse.Namespace(manifest=path, state_directory=self.state, apply=False, prepare=False))
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.getvalue())["clients"][0]["status"], "unowned-or-modified-registration")
        self.assertEqual(json.loads(output.getvalue())["clients"][1], {"client": "pi", "status": "absent", "ok": True})
        self.assertNotIn("2026-11-04", output.getvalue())
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual({item.name: item.read_bytes() for item in self.state.iterdir()}, state_before)
        self.assertFalse(Path(other["target"]).exists())

    def test_invalid_native_configuration_reports_all_clients_without_private_keys(self):
        other = {"kind": "pi", "target": str(self.root / "pi.json"), "desired": None}
        cases = [
            ("codex", '[profiles.personal]\nPRIVATE_KEY_SENTINEL="a"\nPRIVATE_KEY_SENTINEL="b"\n'),
            ("codex", 'PRIVATE_KEY_SENTINEL=' + '[' * 1100 + '0' + ']' * 1100),
            ("claude", '{"PRIVATE_KEY_SENTINEL":' + '[' * 10000 + '0' + ']' * 10000 + '}'),
            ("opencode", '{"PRIVATE_KEY_SENTINEL":' + '[' * 1100 + '0' + ']' * 1100 + '}'),
        ]
        for kind, content in cases:
            with self.subTest(kind=kind, length=len(content)):
                client = {**self.client, "kind": kind}
                if kind == "opencode":
                    client.update(overlay=str(self.root / "fallback.json"), generated=str(self.root / "generated.jsonc"))
                self.target.write_text(content)
                path = self.root / "manifest.json"
                path.write_text(json.dumps({"version": 1, "name": "shared-vault", "clients": [client, other]}))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    code = configure.run(argparse.Namespace(manifest=path, state_directory=self.state, apply=False, prepare=False))
                self.assertEqual(code, 2)
                self.assertEqual(json.loads(output.getvalue())["clients"], [
                    {"client": kind, "status": "invalid-configuration", "ok": False},
                    {"client": "pi", "status": "absent", "ok": True},
                ])
                self.assertNotIn("PRIVATE_KEY_SENTINEL", output.getvalue())
                self.assertEqual(self.target.read_text(), content)
                self.assertEqual(list(self.state.iterdir()), [])

    def test_nonfinite_json_is_held_before_any_configuration_replacement(self):
        for index, literal in enumerate(("1e400", "-1e400", "Infinity", "NaN")):
            for mode in ("prepare", "apply", "check"):
                with self.subTest(literal=literal, mode=mode):
                    state = self.root / f"numeric-state-{index}-{mode}"
                    state.mkdir(mode=0o700)
                    content = '{"mcpServers":{},"unrelated":' + literal + '}\n'
                    self.target.write_text(content)
                    with self.assertRaisesRegex(configure.Conflict, "invalid-configuration"):
                        configure.reconcile(self.client, "shared-vault", state, mode)
                    self.assertEqual(self.target.read_text(), content)
                    self.assertEqual(list(state.iterdir()), [])

    def test_mutable_retry_keeps_recovery_after_crash_at_next_journal(self):
        for index, desired in enumerate((self.entry("v2"), self.entry("v3"), None)):
            with self.subTest(desired=desired):
                folder = self.root / f"client-{index}"
                folder.mkdir()
                self.target = folder / "config.json"
                self.state = self.root / f"state-{index}"
                self.state.mkdir(mode=0o700)
                self.client = {"kind": "cursor", "target": str(self.target), "desired": self.entry("v1")}
                self.apply()
                durable = self.target.read_bytes()
                parent = folder.stat()
                real_fsync = os.fsync

                def fail_publication_flush(descriptor):
                    info = os.fstat(descriptor)
                    if ((info.st_dev, info.st_ino) == (parent.st_dev, parent.st_ino)
                            and self.current()["mcpServers"]["shared-vault"] == self.entry("v2")):
                        raise OSError("injected post-replacement directory flush failure")
                    real_fsync(descriptor)

                self.client["desired"] = self.entry("v2")
                with patch.object(os, "fsync", fail_publication_flush), self.assertRaises(OSError):
                    self.apply()
                self.assertEqual(self.current()["mcpServers"]["shared-vault"], self.entry("v2"))
                self.assertEqual(json.loads(self.owned().read_text())["managed"], [self.entry("v1"), self.entry("v2")])
                self.client["desired"] = desired
                real_journal = configure.journal

                def trace_flush(descriptor):
                    nonlocal durable
                    real_fsync(descriptor)
                    info = os.fstat(descriptor)
                    if (info.st_dev, info.st_ino) == (parent.st_dev, parent.st_ino):
                        durable = self.target.read_bytes()

                def crash_after_journal(path, value, expected):
                    result = real_journal(path, value, expected)
                    if path == self.owned():
                        raise OSError("modeled host crash after durable journal")
                    return result

                with patch.object(os, "fsync", trace_flush), patch.object(configure, "journal", crash_after_journal):
                    with self.assertRaises(OSError):
                        self.apply()
                self.target.write_bytes(durable)
                self.assertEqual(configure.reconcile(self.client, "shared-vault", self.state, "prepare"), "ready")
                self.apply()
                self.assertEqual(self.current().get("mcpServers", {}).get("shared-vault"), desired)

    def test_generated_publication_survives_receipt_settlement_or_supersession(self):
        for mode in ("apply", "prepare"):
            with self.subTest(mode=mode):
                folder = self.root / mode
                folder.mkdir()
                state = self.root / f"state-{mode}"
                target = folder / "opencode.jsonc"
                clients = []
                for version in ("a", "b", "c"):
                    value = {"type": "local", "command": [f"/release-{version}/bin/vault-mcp"], "disabled": False}
                    source = self.root / f"generated-{mode}-{version}.jsonc"
                    source.write_text(json.dumps({"mcp": {"servers": {"shared-vault": value}}}))
                    clients.append({"kind": "opencode", "target": str(target), "overlay": str(folder / "opencode.json"),
                                    "generated": str(source), "desired": value})
                manifest_path = self.root / f"manifest-{mode}.json"

                def execute(client, step):
                    manifest_path.write_text(json.dumps({"version": 1, "name": "shared-vault", "clients": [client]}))
                    with contextlib.redirect_stdout(io.StringIO()):
                        return configure.run(argparse.Namespace(manifest=manifest_path, state_directory=state,
                                                                apply=step == "apply", prepare=step == "prepare"))

                self.assertEqual(execute(clients[0], "prepare"), 0)
                target.symlink_to(clients[0]["generated"])
                self.assertEqual(execute(clients[0], "apply"), 0)
                self.assertEqual(execute(clients[1], "prepare"), 0)
                target.unlink()
                target.symlink_to(clients[1]["generated"])
                durable = clients[0]["generated"]
                parent = folder.stat()
                real_fsync = os.fsync

                def trace_flush(descriptor):
                    nonlocal durable
                    real_fsync(descriptor)
                    info = os.fstat(descriptor)
                    if (info.st_dev, info.st_ino) == (parent.st_dev, parent.st_ino):
                        durable = str(target.resolve(strict=True))

                with patch.object(os, "fsync", trace_flush):
                    self.assertEqual(execute(clients[1 if mode == "apply" else 2], mode), 0)
                target.unlink()
                target.symlink_to(durable)
                self.assertEqual(execute(clients[2], "prepare"), 0, "Crash lost the only approved generated publication")
                target.unlink()
                target.symlink_to(clients[2]["generated"])
                self.assertEqual(execute(clients[2], "apply"), 0)


if __name__ == "__main__":
    unittest.main()
