# Reproduce the shared-vault environment

The committed Nix flake selects the system packages, five agent clients,
independent vault service, scheduler, cleanup timer and notes synchronization.
`home/services/shared-vault-prl-dev-vm-release.json` pins the aarch64-linux
runtime by full Fulcrum commit and SHA256. The archive is retained in the
private `andrearagao/fulcrum` GitHub release named in that pin.

The archive contains certified source and installed native dependencies. It
does not contain credentials, Git metadata or mutable vault data. A bootstrap
command imports the exact archive into Nix, builds its package and restores a
clean checkout of the pinned source under `~/projects/work/fulcrum-releases/`.
Every exported source file and executable mode is compared with the certified package;
the intentionally omitted `.env.example` is checked against the pinned Git commit.
`node_modules` points to that package. The checkout retains real Git metadata
for Fulcrum's installed-version checks. Existing changed checkouts are preserved
and cause an explicit failure.

## Restore code and configuration

Use the `prl-dev-vm` NixOS host configuration on aarch64-linux. Other hosts still
evaluate, but this native archive is not an x86_64 or Darwin release.

Prerequisites are Nix with flakes, Git, Python 3, access to the private Fulcrum
repository and the host's SOPS decryption key. Restore the SSH identities and
the configured `github-work` alias, or use `--source-repository` with an
authenticated repository URL. The download uses `GH_TOKEN`, `GITHUB_TOKEN` or
Git's existing HTTPS credential helper. Credentials are not written into Git,
the release pin or the Nix store.

```sh
mkdir -p ~/projects/personal
git clone git@github.com:andreaugustoaragao/nix.git ~/projects/personal/nix
cd ~/projects/personal/nix
python3 home/cli/shared-vault-bootstrap.py
nix flake check --no-build --all-systems
sudo nixos-rebuild switch --flake ~/projects/personal/nix#prl-dev-vm
```

Restore the mutable state below before activating the production services.
The bootstrap does not start services or change that state. It can be rerun:
the exact existing checkout is verified and reused. GitHub downloads go to a
private temporary directory, are checked against the committed SHA256 and
are removed after Nix imports them. GitHub credentials are removed on asset
redirects.

For an offline restore with a retained archive:

```sh
python3 home/cli/shared-vault-bootstrap.py \
  --archive /path/to/shared-vault-release.tar.gz \
  --source-repository /path/to/fulcrum
```

`--archive-only` imports the verified archive without building or creating a
checkout. It is useful when preparing a Nix store before a full restore.
Private GitHub release URLs cannot be fetched anonymously by a Nix builder;
run the bootstrap after garbage collection removes the fixed-output archive.
The committed URL and hash, rather than a path in one user's home directory,
identify the required input.

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
