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

manifest_path, disabled_path, connection_path, launcher_path, activation_path = map(Path, sys.argv[1:])
manifest = configure.manifest(manifest_path)
disabled = configure.manifest(disabled_path)
connection = json.loads(connection_path.read_text())
assert all(client["desired"] is None for client in disabled["clients"])
assert len(manifest["clients"]) == len(disabled["clients"]) == 6
expected_socket = f"{connection['runtimeDirectory']}/vault-{hashlib.sha256(connection['vaultId'].encode()).hexdigest()[:24]}/api.sock"
assert connection["socketPath"] == expected_socket
expected_arguments = ["--socket", expected_socket, "--vault", connection["vaultId"]]
entries = {client["kind"]: client["desired"] for client in manifest["clients"]}
mcp = str(launcher_path / "bin/vault-mcp")
assert all(entry["command"] == mcp for entry in entries.values() if entry is not None)
assert entries["pi"]["timeout"] == entries["codex"]["tool_timeout_sec"] == 120
assert entries["omp"]["timeout"] == 120000
assert entries["claude"] is None, "Claude Code registrations must remain retired"
assert entries["opencode"] is None, "OpenCode registrations must remain retired"
assert entries["codex"]["startup_timeout_sec"] == 20
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
            Path(native["target"]).write_text('{"mcp": {"servers": {}}}')
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


def opencode_retirement_scenario(root, legacy, has_conflict):
    home = root / "home"
    primary = home / ".config/opencode/opencode.jsonc"
    primary.parent.mkdir(parents=True)
    overlay = primary.with_name("opencode.json")
    if has_conflict:
        fallback = {"shared-vault": {"type": "local", "command": ["unowned"]}}
        overlay.write_text(json.dumps({"mcp": fallback if legacy else {"servers": fallback}}))
        overlay_before = overlay.read_bytes()
    for step in ("sharedVaultClientsPrepare", "sharedVaultClients"):
        result = hook(home, root, "enabled", step)
        if has_conflict and step == "sharedVaultClientsPrepare":
            assert result.returncode != 0, "Unowned OpenCode fallback must fail check"
            assert overlay.read_bytes() == overlay_before
            return
        assert result.returncode == 0, result.stderr


scenarios = [
    (f"opencode-retire-{legacy}-{conflict}", lambda root, legacy=legacy, conflict=conflict: opencode_retirement_scenario(root, legacy, conflict))
    for legacy in (False, True) for conflict in (False, True)
]
failures = []
for name, scenario in scenarios:
    with tempfile.TemporaryDirectory(prefix="shared-vault-activation-") as scratch:
        try:
            scenario(Path(scratch))
        except AssertionError as error:
            failures.append(name + ": " + str(error))
assert not failures, "\n".join(failures)
print("Four native serializations, retired Claude and OpenCode registrations, canonical socket, argument binding, registration and four retirement scenarios pass")
