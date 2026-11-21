# Finish the shared pointer

`prl-dev-vm` and `workstation` share one keyboard and one mouse. The keyboard and mouse stay plugged into the VM. The cursor leaves the VM's left edge and lands on the workstation's portrait monitor (`DP-2`), and it comes back with Scroll Lock.

lan-mouse does the screen edge and the key injection. `cursor-bridge` carries its datagrams. The workstation cannot address `10.211.55.4`, so the VM opens the only connection and both directions ride it.

## Current completion status

- `home/services/cursor-bridge.nix` patches `lan-mouse 0.10.0` (`lanMouse`) so both UDP binds in `src/server/network_task.rs` use `127.0.0.1` instead of `0.0.0.0`, binds `WlrootsEmulation` via verified listener `(st_dev, st_ino)` + `SO_PEERCRED` + `/proc/<pid>/stat` `starttime` + blocking-mode `Connection::from_socket`, retains unreleased keys/buttons/modifiers across `WouldBlock` and handle retirement (`release_keys` / `terminate`), latches absorbing `UNRECOVERED` on unrecovered teardown, and enforces establishment-before-issuance (`floor=0 -> Ping -> serial_established=1 -> floor>=1`) on `native-seat`.
- `home/services/cursor-bridge.nix` configures `layer-shell` capture, `wlroots` emulation, `release_bind = ["KeyScrollLock"]`, `[left]` on `prl-dev-vm`, `[right]` on `workstation`, `%t/cursor-bridge/` (`0700`, `RuntimeDirectoryPreserve = "yes"`), `--niri-bin`/`--busctl-bin`/`--enter-output DP-2` on `workstation`, and `LoadCredential` for `%d/cert` and `%d/key` (no `SupplementaryGroups` and no raw `evdev`).
- `pkgs/cursor-bridge/src/main.rs` separates `--quic-addr` from loopback `--lan-local`/`--lan-peer`, enforces mutual TLS (pinned leaf DER + TLS 1.3 `CertificateVerify`), validates exact `D5` wire frames, uses a persistent `Endpoint` with bounded handshakes and single `500ms` replacement/shutdown deadlines, verifies `DP-2` compositor/logind/lock readiness (`250ms` budget) with `1250ms` bidirectional `Refused` suppression, and runs a single sequential `RecoveryDriver` with establishment-before-issuance (`bridge-serial` / `native-seat`).
- `system/sops.nix` declares `"cursor-bridge/cert"` and `"cursor-bridge/key"` (`0400`, owned by `owner.name`) scoped strictly to `workstation` and `prl-dev-vm`.

## What is left

1. Generate the deployment keypair and encrypt `"cursor-bridge/cert"` and `"cursor-bridge/key"` into `secrets/secrets.yaml` using an environment with an authorized SOPS age key (`umask 077` + `sops set --value-stdin` so the private key never appears in `argv`):

   ```sh
   (
     umask 077
     tmp=$(mktemp -d)
     trap 'rm -rf "$tmp"' EXIT
     openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
       -keyout "$tmp/key.pkcs8.pem" -out "$tmp/cert.pem" -days 3650 -noenc -subj /CN=cursor-bridge
     jq -Rs . < "$tmp/cert.pem" | sops set --value-stdin secrets/secrets.yaml '["cursor-bridge/cert"]'
     jq -Rs . < "$tmp/key.pkcs8.pem" | sops set --value-stdin secrets/secrets.yaml '["cursor-bridge/key"]'
   )
   ```

   Confirm the file still decrypts before committing:

   ```sh
   sops decrypt --extract '["cursor-bridge/cert"]' secrets/secrets.yaml | head -1
   ```

2. Build `pkgs/cursor-bridge`, the patched `lanMouse` derivation, and the `prl-dev-vm` and `workstation` NixOS closures (`validateSopsFiles = true` requires the encrypted secrets to be present).
3. Rebuild and activate `prl-dev-vm` and `workstation`. Verify `127.0.0.1:4242` / `127.0.0.1:4244` loopback binds on both hosts, `0.0.0.0:4243` listener only on `workstation`, mTLS QUIC connection establishment, left-edge crossing from `prl-dev-vm` onto `workstation` `DP-2`, and `KeyScrollLock` return.

## What not to change

- Do not bind `lan-mouse` to anything but `127.0.0.1`. Its own packets are not encrypted, and the return path does not exist for them.
- Do not open a port on the VM. The workstation cannot route to `10.211.55.4`.
- Do not add clipboard sharing. It is out of scope.

## Integration verification (T024 worker, 2026-11-21)

Worktree `/home/aragao/projects/personal/nix-cursor-bridge-review-20261117` only; primary repo not modified.

| Check | Result |
| --- | --- |
| `cargo test --manifest-path pkgs/cursor-bridge/Cargo.toml` | **PASS** — 22/22 |
| `nix build` `cursor-bridge` via `workstation.pkgs.callPackage ./pkgs/cursor-bridge.nix` | **PASS** — `/nix/store/ba0gdqxpwh54j67i7iarigw9v8p42n36-cursor-bridge-0.1.0` |
| `nixfmt --check`, `statix check`, `deadnix` on `home/services/cursor-bridge.nix`, `system/sops.nix` | **PASS** |
| `nix build --dry-run` `workstation` / `prl-dev-vm` `system.build.toplevel` (this worktree, aarch64 evaluator) | **PASS** |
| `nix build` `prl-dev-vm` toplevel (materialize) | **FAIL** — `sops-install-secrets`: `cursor-bridge/cert` missing in checked-in `secrets/secrets.yaml` |

### Primary repo closure prerequisites

- **`system/workstation-build-client.nix` (primary)** — KVM split **already applied**: separate `x86_64-linux` entry with `kvm`, `aarch64-linux` without. Matches `builder-kvm-declaration-r1-20261121/candidate.patch`; no further patch.
- **`system/sops.nix` (primary)** — **missing** `cursor-bridge/cert` and `cursor-bridge/key`; merge from this worktree (`system/sops.nix` lines scoped to `workstation` / `prl-dev-vm`).
- **`secrets/secrets.yaml` (primary and worktree)** — no `cursor-bridge/*` ciphertext yet. Encrypted candidates validated offline only:
  - Flat: `sops-candidate-20261121/result.json` (`encryptedCandidateSHA256` `310440a5…`, `bothNewEntriesDecryptAndMatch`: true, `activation`: false).
  - Nested: `sops-candidate-20261121/nested-r1-result.json` (`9781a4e3…`, cert/key reused, `activation`: false).
  Parent must install one candidate into `secrets/secrets.yaml` on a host with `/var/lib/sops-nix/key.txt` before material host builds succeed.

### Artifact open items (chief-of-staff `artifacts/T024/`)

- **Host activation** — not done (`host-closure-progress-20261121-0156.json`: indexed VM closure ok; primary integration/activation pending).
- **Workstation full closure on remote x86 builder** — prior `workstation-closure-build-r4.json` exited 1 (x86-only derivations such as `workstation-k8s-vm-image` while client advertised combined `x86_64-linux,aarch64-linux` + `kvm` on one builder row). Primary NixOS config now exposes split builders (`builders.stdout` in `builder-kvm-declaration-r1-20261121`); re-run workstation material build after primary merge with trusted-user `builders` or activated `nix.buildMachines`.
- **Two-host journey** — Scroll Lock / DP-2 crossing verification remains post-activation (`host-closure-progress` next_action).
- **Preserve T036 delivery fix** when merging into primary (`host-closure-progress` note).
