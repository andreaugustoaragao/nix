# Shared vault client configuration

`my.sharedVault` supplies one vault identity, Unix socket and immutable release
to Codex, Cursor, Pi, OpenCode and the `vault` CLI. It is disabled by
default. This module installs clients; it does not start a vault service,
initialize a catalog or resume scheduled work.

Before enabling it, certify a release providing `bin/vault-client` and
`bin/vault-mcp` with the explicit `--socket PATH --vault ID` contract. Its
`sharedVaultSourceRevision` passthru must match the declared full `releaseId`.
`pkgs/shared-vault-release.nix` accepts a certified `.tar.gz` archive pin and
whole-file SHA256, package version and reviewed full source revision. The archive
has one top-level directory. Its build checks the archive's
`share/vault-services/release.json` against those declared values and requires
the service, CLI, MCP, Bun and automation bootstrap files. An archive without
the reviewed manifest is rejected. The release build and certification remain
separate from this configuration module.
The `prl-dev-vm` deployment pins its certified archive through
`home/services/shared-vault-prl-dev-vm-release.json`. The current local-only pin
has `url: null`; retain its archive privately and run
`python3 home/cli/shared-vault-bootstrap.py --archive /path/to/shared-vault-release.tar.gz`
from the Nix checkout. For a pin with a private GitHub release URL, omit
`--archive` to download it. The bootstrap verifies and imports the archive,
builds the runtime package and verifies its packaged application identity.
It also imports the separately pinned desktop source archive; supply
`--desktop-archive` when restoring that source offline.
See [environment recovery](../../docs/shared-vault-recovery.md)
for credentials, mutable-state restoration and installed verification.

On Linux, package installation removes ELF files for other CPUs or musl after
archive certification and before strict native fixup. It retains both matching
Bun copies and verifies their bytes. The retained glibc closure includes
libxcb for the shipped X11 native module; missing dependencies still fail the
build. Patching changes installed bytes, so an actual native package build and
installed runtime acceptance on each supported architecture remain release gates.

For a clean, commit-bound Fulcrum checkout with a passing `release` or `focused`
development-certification receipt, run `home/cli/shared-vault-release.py` with
`--worktree`, `--receipt`, `--state-directory` and `--output`. The state directory
must already be private (`0700`); the `.tar.gz` output must be new and directly
inside it. The producer currently requires Linux for process-tree supervision.
It rejects Git replacement objects and materialized tracked files whose raw
bytes or executable modes differ from the unreplaced candidate commit, even
when Git's filtered status reports a clean checkout. It checks this before
the verifier and again before publication. The producer calls that checkout's pinned
`node_modules/bun/bin/bun.exe --no-env-file scripts/development-certification.ts
check --receipt PATH` before and after copying. It requires the receipt to cover
the exact clean commit, package version and full installed dependency digest,
then reruns the existing installed dependency and patch checks on both source
and staged runtime. The digest includes every approved dependency file's bytes
and executable mode, including Bun; the producer checks it against both the
source and the materialized staging tree. Tracked source comes from committed
Git blobs and modes, independent of local archive attributes. The producer
authenticates the candidate commit, reconstructs its root tree from the complete
file inventory, and verifies each exported blob against its object ID. The complete
installed dependency tree is copied with only safe internal file links
materialized. `.env` files, `.git`, caches and
mutable vault data stay out of the archive. The expected staging file inventory
comes from authenticated Git bytes, receipt-bound dependency entries and the
generated runtime contents. Exact paths, bytes, modes and parent-directory sets
must match before the staging tree can become a seal; an export-time Git helper
cannot redefine this baseline. Before running staged checks, the producer seals every
file's bytes and mode and the complete directory inventory, including generated
launchers. Additions, removals, links and changed files make verification fail.
Archive construction uses only that sealed inventory; the emitted archive's
entries, modes and file bytes must also match after the last verifier or Git
command has closed, before the final archive hash and publication. The output is a deterministic,
single-root `.tar.gz` with a SHA256 SRI sidecar suitable for `hash` in the Nix
package call. Each target architecture needs its own certified native archive.
Existing outputs are never replaced. Publication uses owned hardlinks; a failed
or interrupted attempt removes only links to its own temporary files. Successful
staging is removed; failures
retain a private diagnostic under the chosen state directory without publishing
an archive. Each verifier command runs under a Linux subreaper that closes and
reaps its detached descendants on timeout or interruption before reporting a
settled failure. If descendant closure cannot be proved, the diagnostic says
`held`, records the supervisor PID, and keeps any staging directory for recovery.
The small `shared-vault-release` check uses a fake receipt checker
for layout and refusal tests; only a real certification receipt checked by the
candidate's own tool can authorize a release archive.

Set `vaultId` and `runtimeDirectory` to the values selected for the service.
Set `service.recordingsDirectory` to expose capture metadata and verified
transcript windows through the shared read API. Omitting it leaves processing
history readable and the capture catalog explicitly unconfigured. This option
does not activate recording intake or replay existing recordings.
The socket uses the first 24 hexadecimal SHA256 characters of the vault ID:
`RUNTIME/vault-HASH/api.sock`. Evaluation rejects noncanonical runtime paths,
missing identities and socket paths longer than 103 bytes.

`~/.config/shared-vault/connection.json` publishes the nonsecret connection and
release identity for Fulcrum's client handoff. `vault` and `vault-mcp` use the
same values and a store-bound release executable. Neither launcher accepts
connection overrides; an explicit separate raw client is required for another
vault. The CLI preserves arguments after `--` as positional input.

| Client | Owned entry | Native timeout units |
| --- | --- | --- |
| Codex | `~/.codex/config.toml`, `mcp_servers.shared-vault` | Seconds |
| Cursor | `~/.cursor/mcp.json`, `mcpServers.shared-vault` | Client default |
| Pi | `~/.pi/agent/mcp.json`, `mcpServers.shared-vault` | Seconds |
| OpenCode 2 | Existing generated `opencode/opencode.jsonc`, `mcp.servers.shared-vault` | Milliseconds: `startup`, `catalog`, `execution` |

OpenCode 2 uses `disabled`, and a timeout object. Its legacy scalar timeout and
`enabled` fields must not be copied into the native v2 registration. Pi 1.5.0
has native MCP; this module introduces no extension bridge. Credentials,
permissions, hook settings and model choices remain in their existing owners.

Run `vault-client-config check` to compare the declared user registrations and
their ownership journals. It returns JSON client/status rows, exits 2 on drift,
and never prints configuration values or repairs files. OpenCode's optional
JSON file is checked for a conflicting entry even when JSONC currently wins:
otherwise disabling JSONC could expose a forgotten registration. The check
does not certify service availability, project overrides, alternate managed
homes, environment overrides, disabled extensions or client approval state.
Connected acceptance must exercise the actual installed client in its selected
workspace and record the resulting vault and service identities.

Malformed configuration, parser depth limits and nonfinite JSON numbers
(including exponent overflow) stop preflight with a redacted status. The helper
preserves those files for reconciliation instead of normalizing unsupported
values. Valid TOML dates in a modified managed entry also remain untouched.

Activation first checks collisions and records a durable prepared receipt before
Codex's template merge or Home Manager's generated links. Before acknowledging
preparation, the helper flushes the receipt file and its directory ancestry;
failure to flush stops preparation. Retries flush existing ancestry too.
The receipt supports recovery after any generated file; it records only approved immutable source
paths for OpenCode. A regular or foreign primary file containing the reserved
entry is held, as is a conflicting native or legacy fallback. The mutable entry
owner then runs after the existing writers and checks again. It refuses an unowned name collision,
including an identical unowned entry. Each mutable client has a private journal
under `~/.local/state/shared-vault/registrations/`. It records only the owned
entry, never a snapshot of credentials or the whole configuration. Publication
is atomic and records both previous and intended values before replacement.
After interruption, activation can finish or retire either owned generation.
Before narrowing ownership history, the helper flushes the currently observed
mutable file and its directory entries, or the generated link's directory
entries. This also applies when a retry already sees the desired contents and
when a later generation supersedes an interrupted one. A failed flush preserves
the earlier ownership history.
The activation receipt settles only after all clients match; a prepared receipt
is reported as incomplete by the read-only drift check. On completion it retains
only the declared generated source, or none after retirement.
Client results are independent: inspect failed rows and retry after resolving
their conflicts; do not restore an old whole-file snapshot.

Remove a client from `clients`, or set `enable = false`, and activate the
reviewed generation to retire its unchanged owned entry. Keep this module
imported until retirement finishes. The disabled activation hook remains
available for that cleanup. Manually edited entries are held for reconciliation
instead of overwritten or deleted. Keep the compact ownership journals as
retirement receipts; successful writes leave no temporary file behind.

Run activation with other configuration writers quiescent. The reconciler
serializes its own writers and rechecks the source before replacement, but
independent applications do not participate in its advisory lock. Mutable
configuration symlinks and hardlinks are refused; resolve their declarative
owner before changing them. OpenCode's generated link remains owned by its
existing module and is read only by this helper.

The optional `my.sharedVault.service` module installs a Linux user service from
that same release. It remains disabled until migration and cutover. Set the
canonical notes directory, migrated state directory and existing vector
namespace explicitly. The service starts with `--config` and
`--release-manifest`; its manifest reports the artifact revision that Fulcrum
checks against `releaseId`. Automation admission and recording admission default
to paused. When automation is enabled, supply the reviewed Codex executable
path. No startup step initializes or migrates vault state.

`recordingsDirectory` alone provides recording reads. Set `recordingIntake` with
an `agentName` and enable the automation owner to configure shared processing.
The optional `model`, `systemPromptAppend`, `recordCall` and
`google = { account = "..."; executable = "/..."; }` fields select the existing
runtime profile; unset fields are omitted. These values are nonsecret Nix
configuration. Credentials stay with their existing owner. Both admission
settings remain paused by default, even with a complete intake profile.
An enabled recording admission without a profile is rejected during evaluation.

`vault-service-config check` compares the installed connection, service JSON and
complete loaded unit bytes with the Nix generation, validates the artifact
manifest identity, and inspects the loaded user unit for a stale generation or
an overriding drop-in. It prints
only `ok`, `drift` or `unavailable` for each component and exits 2 unless all
match. It does not start the unit, read credentials or certify provider/storage
behavior. A missing user bus reports `unavailable`.

Verification is available through `checks.<system>.shared-vault-configure`
and `checks.<system>.shared-vault-module`. The latter evaluates Home Manager,
checks five native serializations and the canonical socket, runs inert release
launchers, and exercises registration/removal in disposable stores. These
checks do not initialize a real vault or establish six-client parity. Production
activation remains gated by the shared-vault delivery plan, migration rehearsal,
release certification and a fresh checkpoint.
