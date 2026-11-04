# Shared vault client configuration

`my.sharedVault` supplies one vault identity, Unix socket and immutable release
to Codex, Claude, Cursor, Pi, OpenCode and the `vault` CLI. It is disabled by
default. This module installs clients; it does not start a vault service,
initialize a catalog or resume scheduled work.

Before enabling it, certify a release providing `bin/vault-client` and
`bin/vault-mcp` with the explicit `--socket PATH --vault ID` contract. Its
`sharedVaultSourceRevision` passthru must match the declared full `releaseId`.
Set `vaultId` and `runtimeDirectory` to the values selected for the service.
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
| Claude | `~/.claude.json`, `mcpServers.shared-vault` | Client default |
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

Verification is available through `checks.<system>.shared-vault-configure`
and `checks.<system>.shared-vault-module`. The latter evaluates Home Manager,
checks five native serializations and the canonical socket, runs inert release
launchers, and exercises registration/removal in disposable stores. These
checks do not initialize a real vault or establish six-client parity. Production
activation remains gated by the shared-vault delivery plan, migration rehearsal,
release certification and a fresh checkpoint.
