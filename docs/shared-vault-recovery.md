# Reproduce the shared-vault environment

The committed Nix flake selects the system packages, four agent clients
(Codex, Cursor, Pi, OMP), independent Vault v2 overlay (`shared-vault-v2`),
standalone AI task scheduler (`ai-task-scheduler`), Fulcrum web service, and
notes synchronization. `home/services/vault-v2-prl-dev-vm-release.json` pins
the aarch64-linux runtime (`0.226.2`) by full Fulcrum commit, archive SRI hash,
and native binary SHA-256 digests (`shared-vault`, `vault-extract`,
`ai-task-scheduler`). A null `url` selects a local-only release: retain its
certified archive privately outside `/tmp` (e.g.
`~/.local/share/fulcrum-releases/release-0.226.2/shared-vault-release-0.226.2.tar.gz`)
and import it with `--pin` and `--archive-only` before rebuilding. This mode
performs no runtime download or publication; a fresh Nix store cannot recover
from the committed config alone without the retained archive.

The runtime archive contains certified source, built web assets and installed
native dependencies. It does not contain credentials, Git metadata or mutable
vault data. The service runs directly from the resulting Nix store package.
Activation does not create source checkouts or install dependencies. Nix
configuration generations retain the package for rollback and garbage collection.

Fulcrum Desktop has a separate source revision and unpacked SHA256 in
`home/desktop/fulcrum-source.json`. Its Nix derivation fetches that fixed source
archive. It does not read a development checkout or the runtime's Git history.

## Restore code and configuration

Use the `prl-dev-vm` NixOS host configuration on aarch64-linux. Other hosts still
evaluate, but this native archive is not an x86_64 or Darwin release.

Prerequisites are Nix with flakes, Git, Python 3, access to the private Fulcrum
repository and the host's SOPS decryption key. Private GitHub downloads use
`GH_TOKEN`, `GITHUB_TOKEN` or Git's existing HTTPS credential helper. Credentials
are removed on asset/source redirects and never enter the release pins or Nix
store. Runtime and desktop inputs are both verified against committed hashes.

```sh
mkdir -p ~/projects/personal
git clone git@github.com:andreaugustoaragao/nix.git ~/projects/personal/nix
cd ~/projects/personal/nix
python3 home/cli/shared-vault-bootstrap.py \
  --pin home/services/vault-v2-prl-dev-vm-release.json \
  --archive ~/.local/share/fulcrum-releases/release-0.226.2/shared-vault-release-0.226.2.tar.gz \
  --archive-only
nix build --no-link .#nixosConfigurations.prl-dev-vm.config.home-manager.users.aragao.my.vaultV2.package
nix flake check --no-build --all-systems
```

Keep production services and sync timers stopped while restoring the mutable
state below. Activation is a separate final step after that restore.
Both `--pin home/services/vault-v2-prl-dev-vm-release.json` and
`--archive-only` are required for Vault v2: `shared-vault-bootstrap.py` still
defaults to the retired v1 pin and its non-`--archive-only` build target points
at the disabled `my.sharedVault.release` attribute. The import verifies the
archive SRI hash and adds the fixed-output `shared-vault-release.tar.gz` to the
local Nix store without starting services or touching mutable state. Re-run the
import if Nix garbage collection removes the fixed-output archive.

## Restore mutable state

Git reproduces software and configuration. Restore the following from a
consistent private backup to recover the same conversations, originals,
scheduled work and logins. Do not replace a current database with an older
copy while services are running.

| State | Location | Recovery requirement |
| --- | --- | --- |
| Notes, people, topics, attachments | `~/projects/work/notes` | Clone `andrearagao/notes`, then restore ignored/private attachments if present. |
| Fulcrum application data and `.env` | `~/projects/work/notes/.fulcrum` | Restore together with the matching backup. Preserve SQLite WAL files or use a stopped/SQLite-aware backup. |
| Vault v2 derived overlay index | `~/.local/share/fulcrum-v2/shared-vault-v2` | Optional to restore (`derived-index.db` + `memory_i8` vectors rebuild cleanly from `~/projects/work/notes`, though restoring skips initial ONNX re-embedding). |
| AI Task Scheduler state | `~/.local/share/fulcrum-v2/ai-task-scheduler` | Restore to preserve scheduled rules, run history, and pending delivery outbox. |
| Legacy v1 rollback archive | `~/.local/share/fulcrum-v1-rollback/` (outside Vault Directory) | Retained separately for v1 rollback; ChromaDB and v1 `shared-vault.service` are retired. |
| Call media/transcripts | `~/recordings/calls` | Restore retained recordings and processing evidence together. |
| Provider and Google logins | SOPS secrets and each harness/tool's private login state | Restore SOPS decryption identity; reauthenticate OAuth sessions when needed. |
| Local TLS and trusted CA | Paths declared by `my.fulcrum.localTls` | Restore the existing identity or deliberately reprovision trust. |
| Local embedding models | `~/.cache/fulcrum/embeddings` | Restore the cache for offline operation; model download availability is a separate prerequisite. |

The original activation and source backups from November 7 remain under
`~/.local/share/vault-services/backups/`. They are local recovery copies; this
document does not claim they are an off-machine backup of current live state.
Keep a private off-machine backup of mutable data and decryption keys as part
of the machine's backup procedure.

## Activate after restoring state

Only after the private state and decryption keys are restored, activate the
configuration. This command starts the production services and persistent
timers, including the scheduler and notes sync:

```sh
sudo nixos-rebuild switch --flake ~/projects/personal/nix#prl-dev-vm
```

## Verify the restored installation

```sh
vault-v2-client-config check
systemctl --user is-active shared-vault-v2.service ai-task-scheduler.service fulcrum.service
shared-vault status --socket /run/user/1000/shared-vault-v2/api.sock
vault-extract check-sandbox --json
curl -fsSk https://127.0.0.1:3100/api/health
systemctl --user list-timers notes-sync.timer
```

Verify both JSON objects emitted by `vault-v2-client-config check` report
`activation: "settled"` with all four clients (`codex`, `cursor`, `pi`, `omp`)
`configured`, and confirm `~/.agents/skills/vault-companion/SKILL.md` and
`~/.cursor/skills/vault-companion/SKILL.md` resolve to the pinned release.
Installed acceptance remains distinct from Nix evaluation or archive import.
