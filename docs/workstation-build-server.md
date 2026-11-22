# Workstation agent and build server

The workstation hosts an isolated KVM worker for agent jobs and compilation.
The desktop, Kubernetes guest, and worker have separate kernels and state.
Shared Vault deployment on the workstation remains deferred.

Host activation and worker identity enrollment use local GUI authentication.
The checks below describe the delivery gates.

## Accepted design

The worker has 20 virtual CPUs and 96 GiB RAM. Its host unit caps CPU use at
20 cores and memory at 104 GiB. The workstation retains headroom and gives
its desktop higher scheduling priority. The existing Kubernetes guest is unchanged.

The worker has no host filesystem shares, desktop credentials, GPU passthrough,
or privileged host socket. Jobs run as an unprivileged user against source copies.
Nix store access uses a separate SSH account and key, with a forced store protocol.
Only root is trusted by the Nix daemon. Neither worker access method can activate
the workstation configuration.

Each client and the worker have distinct root-held Nix signing keys. Clients
trust the worker's public key for build results. The worker trusts the pinned
client public keys for imported build inputs, including locally built inputs.
The Nix SSH account remains untrusted. Initial client activation signs existing
store paths once; the daemon signs new paths automatically. The signing keys
stay under `/var/lib/workstation-build-client` and are never copied between hosts.
`workstation-build-client-identity` exports only the public key using GUI authentication.

The worker builds x86 Linux outputs natively. ARM Linux Nix builds can execute
through user-mode emulation. Projects that support cross-compilation can use it
for ARM outputs instead. Emulation supplies compatibility, not native ARM speed.
Rust jobs use per-job target directories and a shared user-owned compiler cache.

Codex, Pi, and Cursor Agent are pinned in `pkgs/agent-binaries/releases.json`.
Pi also has an integrity-complete dependency lock. Their settings and skills stay
in the shared Home Manager modules. Binary updates require an explicit Nix pin
change and authenticated activation. Agent credentials are encrypted with SOPS and materialized only at runtime.
The worker receives a separate, minimal bundle, encrypted to its own age key.

## Delivery checks

1. Build and exercise the pinned agents on ARM and x86 Linux.
2. Verify that Zoom, Aptakube, host Docker services and privileged socket are absent.
3. Boot the worker with KVM and verify its actual resource limits and network policy.
4. Prove Nix remote builds for x86 and ARM, and Rust compilation in project copies.
5. Verify source copies do not change the originating project and concurrent jobs
   do not share mutable target directories.
6. Check authentication, SSH key restrictions, existing desktop and Kubernetes
   services, and the development VM's unchanged Shared Vault runtime.

The alternative of running agents under the desktop user was rejected because
it would expose desktop files and credentials. A separate unprivileged host
account reduces file access but shares the desktop kernel; the user selected KVM.

## Run jobs

After the worker's SSH host key and cache signing key are pinned, both clients
use the `workstation-worker` SSH alias. Nix builds use the configured remote
builder. The worker accepts source snapshots over SSH without host shares.

```sh
workstation-job cargo --system x86_64-linux ./my-project -- build --release
workstation-job cargo --system aarch64-linux ./my-project -- test
workstation-job nix --system aarch64-linux ./my-project -- .#my-package
workstation-job agent ./my-project -- codex
workstation-job status JOB_ID
workstation-job diff JOB_ID
workstation-job fetch JOB_ID target/release/my-program ./downloaded-program
workstation-job remove JOB_ID
```

Each submission creates a separate Git snapshot and target directory under
`~/projects/personal/worker-jobs` or `~/projects/work/worker-jobs`, matching the
source category. Use `--category` to override the inferred category. Ignored
files, including ignored credentials and build outputs, are not uploaded.
Tracked files remain included even when an ignore rule matches them. Submit
nested repositories separately. Review remote changes with `diff`; the command
never applies them to the originating project.

Cargo jobs use the project's dev shell when it has a flake. Otherwise they use
the shared pinned Rust shell. ARM jobs execute ARM tools through emulation unless
the project explicitly configures cross-compilation. Native dependencies remain
the project's responsibility. The worker cache persists across jobs.

The Vim editor extension is pinned as an immutable Nix package. Pi does not
resolve its version through a mutable npm installation.

Agent Hub runs as one Nix-managed user service with a private local socket.
Its CLI, Pi extension and Cursor hooks use a separate immutable runtime pin.
Installing it does not enable Shared Vault. The private archive must be copied
into the builder's Nix store before building; no Fulcrum checkout is required.
Home Manager preserves existing unmanaged wrappers and the service file under
`~/.local/state/nix-agent-adoption` before adopting their paths.

Agent credentials are intentionally separate from desktop credentials. Complete
any required agent login inside the worker before submitting model workloads.
The worker has shared settings and skills but receives no desktop authentication
files or forwarded SSH agent.

## Update the worker image

A workstation rebuild builds the guest image but preserves the running worker.
Run `workstation-worker-update` on the workstation to restart it with that image,
using GUI authentication. Finish active jobs first. Home directories, job copies,
compiler cache, SSH host identity, and cache signing identity stay on the separate
persistent disk. Neither this operation nor normal host updates touch the
Kubernetes guest. The root disk and Nix store are replaced by this updater;
fetch required Nix outputs before updating. Rust target directories and sccache
remain on the persistent home disk.

Rootful Docker retirement stops its containers and daemon. Its former data stays
offline; it is not copied into the worker. New container work uses rootless Docker.

## Evolve the shared agent configuration

`home/cli/agents.nix` is imported by the desktops and the worker through the same
CLI module. Edit that source once, then deploy the same checked Git revision to
each machine. Each machine keeps its own configuration checkout and runtime state.
Do not copy mutable agent homes between machines.

The `agent-desktop-parity` flake check compares all three profiles. It checks the
managed skills and instructions, Pi extensions, agent versions, Codex, Cursor,
and OMP configuration, and cloud models. Store hashes can differ
between CPU architectures. Local model providers and the deferred Shared Vault
registration are deliberate exceptions. A divergent harness fails the check.

Herdr Desktop here can open a remote space backed by the worker's Nix-managed
`herdr-core`. Register it once with `hc machine add workstation-worker`, without
`--install`, then use a remote space for the job's source directory. The worker's
core terminals persist after an SSH disconnect because the user manager lingers.
The shared Pi Preview extension publishes private transcript snapshots in the
worker. Herdr Preview reads them through the registered machine connection and
checks the agent's process identity on that machine before displaying a reply.

## Worker credentials and graphical applications

The worker generates its own SSH host key, Nix cache signing key, age key and
strong keyring password on its persistent disk. The private identity directory is
root-only. `workstation-worker-identities` uses GUI authentication on the host to
read only public keys through the QEMU guest channel. Pin those SSH/cache keys
before enabling clients. Do not trust an unauthenticated SSH key scan.

At enrollment, add a worker SOPS creation rule before the general rule. Encrypt
its bundle using worker and recovery recipients. The exact allowlist in
`secrets/workers/credential-names.json` includes the four model API credentials,
the GitHub token, personal and work SSH/signing keys and passphrases, and the work
Git identity. The worker is never added as a recipient of `secrets/secrets.yaml`.
OAuth logins, Cursor login and browser profiles remain initialized inside the
worker. No desktop authentication directory is copied or forwarded.

The worker reads its GitHub token from SOPS at each `gh` invocation, including
Git's HTTPS credential helper. Signing uses the selected personal or work key
and passes its SOPS passphrase on a private file descriptor. A headless SSH agent
loads the two selected Git identities for SSH remotes. A separate early service
prepares the private SSH directory before decryption. Secret changes refresh only
managed agent keys, retaining unrelated identities; an atomic public-key ledger
also retains interrupted refreshes for cleanup on retry. Git commits, tags and
GitHub releases can therefore be signed and published directly in the worker.

From the checked configuration checkout, run
`workstation-worker-enroll --identities /path/to/authenticated-public-identities.json`.
This pins the public host/cache keys, inserts the specific recipient rule and
encrypts the selected values in memory. It never writes a plaintext credential
file. Review the resulting public pins and encrypted bundle before deployment.
Enrollment refuses a changed existing identity; key rotation requires review.
If your account cannot decrypt the source bundle, add
`--runtime-secrets /run/secrets --runtime-home /home/aragao
--github-token-from-gh` to read only the selected already-decrypted credentials
and the active `github.com` token. The token and plaintext bundle stay in memory.
An existing encrypted bundle remains unchanged unless
`--refresh-from-runtime` is explicitly supplied with runtime sources. Refreshes
retain the pinned worker and recovery identities.

The worker has a private headless Sway session with software rendering, the same
managed `accounts` and `development` browsers, browser-task tooling, GTK/Qt
support and fonts. This supports browser tests and native Rust GUI applications;
it does not measure hardware GPU performance. The account has no wheel/sudo or
host device access. Applications in the worker share that account and its secrets.
Use a separate VM for code that must not access those credentials.

Run `workstation-desktop` on either desktop to review and interact with the guest.
The VNC server listens only on guest loopback. The client creates an authenticated
SSH tunnel ending in a private local Unix socket and disables clipboard sharing.
No VNC/CDP port is exposed to the LAN. Guest-owner SSH permits local tunnels to
its own loopback for desktop review and web development. The Nix store account
cannot forward anything. Host SSH forwarding policy is unchanged.

Agent and build terminals inherit the virtual desktop environment. Use
`agent-browser-mode accounts visible` inside the guest for a browser login,
following the normal browser-task ownership procedure, then return it to headless
mode when finished. API credentials are usable before interactive OAuth login.
The worker keyring unlocks from its own systemd credential, so SSH key login does
not require an empty keyring password or a copied desktop password.

## Preserve the desktop during activation

The build host uses disk-backed `/tmp`. Changing an existing `/tmp` mount needs
a boot-only update and reboot. Stopping the live mount also stops D-Bus because
the broker uses `PrivateTmp`, which can break the active graphical session.
The rebuild helper rejects that transition before authorization. It also checks
the actual active system path before reporting a successful switch.
