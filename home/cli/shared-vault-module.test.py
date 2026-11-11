"""Exercise Nix-rendered registrations and inert release launchers."""

import hashlib
import graphlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("configure", Path(__file__).with_name("shared-vault-configure.py"))
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)

manifest_path, disabled_path, connection_path, opencode_path, launcher_path, activation_path = map(Path, sys.argv[1:])
manifest = configure.manifest(manifest_path)
disabled = configure.manifest(disabled_path)
connection = json.loads(connection_path.read_text())
assert all(client["desired"] is None for client in disabled["clients"])
assert len(manifest["clients"]) == len(disabled["clients"]) == 5
expected_socket = f"{connection['runtimeDirectory']}/vault-{hashlib.sha256(connection['vaultId'].encode()).hexdigest()[:24]}/api.sock"
assert connection["socketPath"] == expected_socket
expected_arguments = ["--socket", expected_socket, "--vault", connection["vaultId"]]
entries = {client["kind"]: client["desired"] for client in manifest["clients"]}
mcp = str(launcher_path / "bin/vault-mcp")
assert all(entry["command"] == ([mcp] if kind == "opencode" else mcp) for kind, entry in entries.items() if entry is not None)
assert entries["opencode"]["timeout"] == {"startup": 20000, "catalog": 20000, "execution": 120000}
assert entries["opencode"]["disabled"] is False
assert entries["pi"]["timeout"] == entries["codex"]["tool_timeout_sec"] == 120
assert entries["claude"] is None, "Claude Code registrations must remain retired"
assert entries["codex"]["startup_timeout_sec"] == 20
assert json.loads(opencode_path.read_text())["mcp"]["servers"]["shared-vault"] == entries["opencode"]

def run(command):
    return subprocess.run(command, capture_output=True, text=True, timeout=10, check=False)

reply = run([mcp])
assert reply.returncode == 0 and json.loads(reply.stdout) == expected_arguments
assert run([mcp, "--vault", "wrong"]).returncode == 2
cli = str(launcher_path / "bin/vault")
literal = "literal $(printf never) `printf never` with spaces"
reply = run([cli, "search", literal])
assert reply.returncode == 0 and json.loads(reply.stdout) == expected_arguments + ["search", literal]
assert run([cli, "--socket=/tmp/wrong", "status"]).returncode == 2
reply = run([cli, "search", "--", "--vault"])
assert reply.returncode == 0 and json.loads(reply.stdout) == expected_arguments + ["search", "--", "--vault"]

with tempfile.TemporaryDirectory(prefix="shared-vault-module-") as scratch:
    root = Path(scratch)
    state = root / "state"
    state.mkdir(mode=0o700)
    for client in manifest["clients"]:
        native = dict(client, target=str(root / client["kind"]))
        if native["kind"] == "opencode":
            Path(native["target"]).symlink_to(opencode_path)
            native["overlay"] = str(root / "extra-opencode.json")
        if native["kind"] == "claude":
            Path(native["target"]).write_text('{"preferences": {"keep": true}}')
            former = dict(native, desired={"type": "stdio", "command": "retired-client", "args": []})
            configure.reconcile(former, manifest["name"], state, "apply")
        configure.reconcile(native, manifest["name"], state, "apply")
        expected = "configured" if native["desired"] is not None else "absent"
        assert configure.reconcile(native, manifest["name"], state) == expected
        if native["kind"] == "claude":
            preserved = json.loads(Path(native["target"]).read_text())
            assert preserved["preferences"] == {"keep": True}
            assert manifest["name"] not in preserved.get("mcpServers", {})
        native["desired"] = None
        if native["kind"] == "opencode":
            Path(native["target"]).unlink()
            Path(native["target"]).write_text('{"mcp": {"servers": {}}}')
        configure.reconcile(native, manifest["name"], state, "apply")
        assert configure.reconcile(native, manifest["name"], state) == "absent"

activations = json.loads(activation_path.read_text())


def hook(home, root, generation, name):
    source_manifest = manifest_path if generation == "enabled" else disabled_path
    local_manifest = root / (generation + ".json")
    local_manifest.write_text(source_manifest.read_text().replace("/home/fixture", str(home)))
    fragment = activations[generation].get(name, {}).get("data", "")
    fragment = fragment.replace(str(source_manifest), str(local_manifest)).replace("/home/fixture", str(home))
    return run(["bash", "-c", 'set -e\nrun() { "$@"; }\n' + fragment])


def prepare_fixture(root, complete=False, matching_overlay=False):
    home = root / "home"
    primary = home / ".config/opencode/opencode.jsonc"
    primary.parent.mkdir(parents=True)
    if matching_overlay:
        primary.with_name("opencode.json").write_text(opencode_path.read_text())
    prepared = hook(home, root, "enabled", "sharedVaultClientsPrepare")
    assert prepared.returncode == 0, prepared.stderr
    primary.symlink_to(opencode_path)
    if complete:
        connection_file = home / ".config/shared-vault/connection.json"
        connection_file.parent.mkdir(parents=True)
        connection_file.symlink_to(connection_path)
        applied = hook(home, root, "enabled", "sharedVaultClients")
        assert applied.returncode == 0, applied.stderr
    return home, primary


def retire(home, root, primary):
    activation = activations["disabled"]
    graph = {name: set(value["after"]) for name, value in activation.items()}
    for name, value in activation.items():
        for successor in value["before"]:
            graph.setdefault(successor, set()).add(name)
    for name in graphlib.TopologicalSorter(graph).static_order():
        if name == "linkGeneration":
            primary.unlink(missing_ok=True)
            inactive = next(client for client in disabled["clients"] if client["kind"] == "opencode")
            if inactive.get("generated"):
                primary.symlink_to(inactive["generated"])
        elif name.startswith("sharedVaultClients"):
            result = hook(home, root, "disabled", name)
            if result.returncode != 0:
                return result
    return result


def retirement_conflict(root, legacy, completed_activation, matching_overlay=False):
    home, primary = prepare_fixture(root, completed_activation, matching_overlay)
    before = primary.read_bytes()
    overlay = primary.with_name("opencode.json")
    if not matching_overlay:
        fallback = {"shared-vault": {"type": "local", "command": ["unowned"]}}
        overlay.write_text(json.dumps({"mcp": fallback if legacy else {"servers": fallback}}))
    overlay_before = overlay.read_bytes()
    result = retire(home, root, primary)
    assert result.returncode != 0, "Unowned fallback must prevent retirement"
    assert primary.exists() and primary.read_bytes() == before, "Failed retirement exposed the unowned fallback"
    assert overlay.read_bytes() == overlay_before


def manual_primary(root, symlink):
    home, primary = prepare_fixture(root, complete=True)
    primary.unlink()
    manual = {"mcp": {"servers": {"shared-vault": {"type": "local", "command": ["manual"]}}}}
    if symlink:
        foreign = root / "foreign.jsonc"
        foreign.write_text(json.dumps(manual))
        primary.symlink_to(foreign)
    else:
        primary.write_text(json.dumps(manual))
    before = primary.read_bytes()
    result = hook(home, root, "enabled", "sharedVaultClientsPrepare")
    assert result.returncode != 0, "Manual primary must block publication"
    assert primary.read_bytes() == before


def normal_lifecycle(root):
    home, primary = prepare_fixture(root, complete=True)
    again = hook(home, root, "enabled", "sharedVaultClientsPrepare")
    assert again.returncode == 0, again.stderr
    assert retire(home, root, primary).returncode == 0


scenarios = [(f"fallback-{legacy}-{complete}", lambda root, legacy=legacy, complete=complete: retirement_conflict(root, legacy, complete))
             for legacy in (False, True) for complete in (False, True)]
scenarios += [
    ("first-publication-interruption", lambda root: retirement_conflict(root, False, False, True)),
    ("manual-primary", lambda root: manual_primary(root, False)),
    ("foreign-primary-link", lambda root: manual_primary(root, True)),
    ("normal-lifecycle", normal_lifecycle),
]
failures = []
for name, scenario in scenarios:
    with tempfile.TemporaryDirectory(prefix="shared-vault-activation-") as scratch:
        try:
            scenario(Path(scratch))
        except AssertionError as error:
            failures.append(name + ": " + str(error))
assert not failures, "\n".join(failures)
print("Four native serializations, retired Claude registration, canonical socket, argument binding, registration and eight activation scenarios pass")
