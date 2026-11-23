# Reproduce the shared-vault environment

The committed Nix flake selects the system packages, four agent clients
(Codex, Cursor, Pi, OMP), independent Vault v2 overlay (`shared-vault-v2`),
standalone AI task scheduler (`ai-task-scheduler`), Fulcrum web service, and
notes synchronization. The `fulcrum-src` flake input in `flake.nix` / `flake.lock`
pins Fulcrum by exact Git commit and NAR hash and builds three split derivations:

- `pkgs/vault-v2.nix` (`fulcrum-vault-v2`): Rust binaries (`shared-vault`,
  `vault-extract`, `ai-task-scheduler`), filtered to `Cargo.toml`, `Cargo.lock`,
  and `services/` so TypeScript-only updates hit the Nix store cache.
- `pkgs/fulcrum-node-modules.nix` (`fulcrum-node-modules`): fixed-output
  production dependency closure (verified against `bun.lock` and `patches/`),
  cached across releases until dependencies or patches change.
- `pkgs/fulcrum-app.nix` (`fulcrum-app`): stages runtime source, links
  production `node_modules`, runs `bun scripts/build-web.ts`, emits `release.json`
  bound to `fulcrum-src.rev`, and verifies the built web payload.

No local release tarballs or bootstrap import steps are required. All services
run directly from `/nix/store`. Nix configuration generations retain closures
for rollback and garbage collection.

Fulcrum Desktop has a separate source revision and unpacked SHA256 in
`home/desktop/fulcrum-source.json`. Its Nix derivation fetches that fixed source
archive. It does not read a development checkout or the runtime's Git history.

## Restore code and configuration

Use the `prl-dev-vm` NixOS host configuration on `aarch64-linux`. Other hosts still
evaluate, but the Linux runtime packages are built for `aarch64-linux` / `x86_64-linux`.

Prerequisites are Nix with flakes, Git, SSH access to the private Fulcrum
repository (`github-work` host alias), and the host's SOPS decryption key.

```sh
mkdir -p ~/projects/personal
git clone git@github.com:andreaugustoaragao/nix.git ~/projects/personal/nix
cd ~/projects/personal/nix
nix build --no-link .#fulcrum-vault-v2 .#fulcrum-node-modules .#fulcrum-app
nix flake check --no-build --all-systems
```

To update Fulcrum to a newly merged `main` commit:

```sh
cd ~/projects/personal/nix
nix flake update fulcrum-src
nix build --no-link .#fulcrum-vault-v2 .#fulcrum-node-modules .#fulcrum-app
```

To certify a candidate commit before merging to `main`, realize the split
outputs with `--override-input fulcrum-src "git+file://$WORKTREE?rev=$CANDIDATE"`
and pass the resulting `/nix/store` paths to `bun run dev:certify -- run` via
`--realized-vault`, `--realized-app`, and `--realized-node-modules`. Because
`fulcrum-app` embeds `fulcrum-src.rev` in `release.json`, a `git merge --no-ff`
keeps identical `fulcrum-vault-v2` and `fulcrum-node-modules` store paths while
rebuilding `fulcrum-app` (~2s) for the merge commit; after locking the merge
commit with `nix flake update fulcrum-src`, verify the Home Manager target's
realized app output with `bun run dev:certify -- check --receipt "$RECEIPT_FILE"
--integrated-commit "$MERGE_COMMIT" --realized-app "$DEPLOYED_APP_PATH"` before
activation.
Keep production services and sync timers stopped while restoring the mutable
state below. Activation is a separate final step after that restore.

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
