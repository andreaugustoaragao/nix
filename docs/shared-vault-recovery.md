# Reproduce the shared-vault environment

The committed Nix flake selects the system packages, five agent clients,
independent vault service, scheduler, cleanup timer and notes synchronization.
`home/services/shared-vault-prl-dev-vm-release.json` pins the aarch64-linux
runtime by full Fulcrum commit and SHA256. The archive is retained in the
private `andrearagao/fulcrum` GitHub release named in that pin.

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
python3 home/cli/shared-vault-bootstrap.py
nix flake check --no-build --all-systems
```

Keep production services and sync timers stopped while restoring the mutable
state below. Activation is a separate final step after that restore.
The bootstrap imports the pinned runtime and desktop source into Nix, builds the
runtime package and verifies its identity. It does not start services, change
mutable state or create project directories. Repeated imports reuse the verified
store paths. Downloads use private temporary directories that are removed after
import.

For an offline restore with a retained archive:

```sh
python3 home/cli/shared-vault-bootstrap.py \
  --archive /path/to/shared-vault-release.tar.gz \
  --desktop-archive /path/to/fulcrum-desktop-source.tar.gz
```

`--archive-only` imports only the verified runtime archive without building it.
Private GitHub release/source URLs cannot be fetched anonymously by a Nix
builder. Run the bootstrap after garbage collection removes either fixed-output
input. Keep both archives for offline recovery. The committed revisions and
hashes identify the inputs independently of paths in a user's home directory.

## Restore mutable state

Git reproduces software and configuration. Restore the following from a
consistent private backup to recover the same conversations, originals,
scheduled work and logins. Do not replace a current database with an older
copy while services are running.

| State | Location | Recovery requirement |
| --- | --- | --- |
| Notes, people, topics, attachments | `~/projects/work/notes` | Clone `andrearagao/notes`, then restore ignored/private attachments if present. |
| Fulcrum application data and `.env` | `~/projects/work/notes/.fulcrum` | Restore together with the matching shared-vault snapshot. Preserve SQLite WAL files or use a stopped/SQLite-aware backup. |
| Shared catalog, retained originals, audit and scheduler state | `~/.local/share/shared-vault/work-notes` | Restore the entire private directory, including its identity markers and original objects. Normal service startup intentionally never initializes or migrates it. |
| Vector database | `~/projects/work/notes/.fulcrum/chroma` (digest-pinned image in `home/services/chroma.nix`) | Restore its matching backup, or rebuild derived embeddings through the supported service workflow. |
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
vault-service-config check
systemctl --user is-active shared-vault.service fulcrum.service
vault status
systemctl --user list-timers shared-vault-artifacts-cleanup.timer notes-sync.timer
```

Use the installed CLI's `vault --help` if a command contract changes. Check
service identity against the release pin, then test a real note search and the
Fulcrum web application. Installed acceptance remains distinct from a Nix
evaluation or a successful archive download. The existing release acceptance
record covers scheduler execution and the five configured harnesses; Claude
provider authentication still depends on its private login state.
