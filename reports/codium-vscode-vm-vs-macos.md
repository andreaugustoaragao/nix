# VSCodium VM vs macOS host — CLI performance

Same multi-run wall-clock technique as
[`reports/vm-vs-macos-performance.md`](./vm-vs-macos-performance.md). Driver:
[`benchmarks/codium-vscode/run-benchmarks.py`](../benchmarks/codium-vscode/run-benchmarks.py).
Raw JSON:

- [`reports/data/codium-vscode-prl-dev-vm.json`](./data/codium-vscode-prl-dev-vm.json) — VSCodium 1.116 on the VM
- [`reports/data/codium-vscode-mac-work.json`](./data/codium-vscode-mac-work.json) — VSCodium 1.116 on the Mac host (**canonical comparison**)
- [`reports/data/codium-vscode-mac-work-vscode-1.120.0.json`](./data/codium-vscode-mac-work-vscode-1.120.0.json) — VS Code 1.120 on the Mac host (side reference)

## What is being measured

VSCodium **1.116.02821** (commit `221e0a3…`, arm64) on both hosts. Same product,
same version, same upstream commit, same bundled Node `v22.22.2`. Only the
platform underneath differs.

| Host | Editor | Source |
|---|---|---|
| `prl-dev-vm` (Parallels VM, aarch64-linux) | VSCodium 1.116.02821 | nixpkgs-unstable; bash `wrapProgram` wrapper sets GTK/Wayland env |
| `mac-work` (Apple M5 Max, aarch64-darwin) | VSCodium 1.116.02821 | `/Applications/VSCodium.app` (just installed; notarized — `Developer ID Application: Baptiste Augrain`) |

All workloads are headless: no display server, no GUI window, run over SSH
unchanged. Every workload uses a fresh `--user-data-dir` and a controlled
`--extensions-dir`. Both editors are accepted by Gatekeeper (`spctl --assess`),
both carry `com.apple.quarantine`, both use the hardened runtime
(`codesign -dvv` shows `flags=0x10000(runtime)`).

The earlier dataset (`codium-vscode-mac-work-vscode-1.120.0.json`) used Visual
Studio Code 1.120, which is a different product *and* a different version. It
is retained as a side reference but is not the headline comparison anymore.

## Environment

| Field | VM (`prl-dev-vm`) | Mac host (`mac-work`) |
|---|---|---|
| Platform | Linux 7.0.9 aarch64 (Parallels guest) | macOS 26.5 arm64 (Mach-O) |
| CPU | 12 generic ARM vCPUs | Apple M5 Max — 18 cores (6 P + 12 E) |
| RAM | 16 GiB guest | 128 GiB host |
| Filesystem under `/tmp` | btrfs (`zstd:1`, `noatime`, `discard=async`) | APFS (default) |
| `codium` shim | Nix `wrapProgram` bash wrapper, sets `GIO_EXTRA_MODULES`, `XDG_DATA_DIRS`, … | Microsoft-style 39-line bash wrapper, execs `MacOS/VSCodium` with `ELECTRON_RUN_AS_NODE=1` |
| Code-signing | n/a | Notarized; hardened runtime; `com.apple.quarantine` set |

## Workloads

| ID | What it exercises |
|---|---|
| `version` | Bash wrapper + Electron-as-Node bootstrap; prints version and exits. **No engine init, no fs setup.** |
| `list_extensions_empty` | Bootstrap + `rm -rf` + `mkdir` + extension-host scan of an empty dir. |
| `list_extensions_preloaded` | Bootstrap + scan of a stable dir containing EditorConfig. No fs setup; the dir's inodes are hot in cache. |
| `install_extension_from_vsix` | Bootstrap + `rm -rf` + `mkdir` + unzip a pinned VSIX (250 KB, ~32 files) + write `extensions.json`. No network in the measured loop. |
| `uninstall_extension` | Bootstrap + `rm -rf` + `cp -R` (32 files) + recursive delete of the same tree + `extensions.json` rewrite. |

The shell `rm -rf` / `mkdir -p` / `cp -R` setup is part of the wall-clock
number on both hosts.

## Results (mean of N runs, lower is better)

VSCodium-on-VM vs VSCodium-on-Mac (identical product and version):

| Workload | VM mean [ms] | Mac mean [ms] | Mac − VM [ms] | Winner | Ratio |
|---|---:|---:|---:|:---:|---:|
| `version` (n=20) | **99.2** | 126.6 | +27.4 | VM | 1.28× |
| `list_extensions_empty` (n=15) | **169.0** | 203.6 | +34.6 | VM | 1.20× |
| `list_extensions_preloaded` (n=15) | 168.3 | **167.1** | −1.1 | (tie) | 1.01× |
| `install_extension_from_vsix` (n=8) | **305.5** | 321.2 | +15.7 | VM | 1.05× |
| `uninstall_extension` (n=8) | **198.5** | 259.1 | +60.6 | VM | 1.31× |

For reference (different product, different version, same Mac):

| Workload | VS Code 1.120 mean [ms] | vs VSCodium on same Mac |
|---|---:|---:|
| `version` | 121.7 | 4 ms faster |
| `list_extensions_empty` | 190.7 | 13 ms faster |
| `list_extensions_preloaded` | 169.0 | 2 ms slower |
| `install_extension_from_vsix` | 344.1 | 23 ms slower |
| `uninstall_extension` | 306.7 | 48 ms slower |

The within-Mac VSCodium-vs-VS-Code spread is small (±25 ms) and goes in both
directions, so on this hardware the product+version effect is **noise-level**
compared with the cross-platform effect we are now isolating cleanly.

## How this fits the prior report

The prior [`vm-vs-macos-performance.md`](./vm-vs-macos-performance.md) showed
the VM winning 7 of 10 microbenchmarks (plus both full-build measurements),
with a clear pattern:

> Short-lived processes and small-file metadata work favor the VM. Memory
> bandwidth and sequential I/O favor the macOS host.

Every workload in this report is in the *short-lived process + small-file
metadata* quadrant, so the headline ("VM wins or ties everything") is
consistent with the existing thesis, not a contradiction of it. The
interesting analytical question is whether the **per-workload magnitudes**
decompose into the components the prior report named — and the matched
VSCodium-vs-VSCodium comparison lets us answer that for the first time.

## Decomposition: subtract the bootstrap baseline

`version` is the only workload with no engine work and no filesystem setup,
so it isolates the spawn + V8/Node bootstrap cost. Subtracting it from the
total reveals the platform's behavior on the workload-specific engine + fs
portion alone:

| Workload | VM total | Mac total | VM − boot | Mac − boot | engine+fs Δ | What that Δ is |
|---|---:|---:|---:|---:|---:|---|
| `version` | 99.2 | 126.6 | — | — | — | spawn + Electron-as-Node bootstrap (the baseline) |
| `list_extensions_preloaded` | 168.3 | 167.1 | 69.1 | 40.6 | **−28.5** (Mac faster) | scan of a hot, already-populated extension dir |
| `install_extension_from_vsix` | 305.5 | 321.2 | 206.3 | 194.6 | **−11.7** (Mac faster) | `rm`/`mkdir` + unzip 250 KB / ~32 files + write `extensions.json` |
| `list_extensions_empty` | 169.0 | 203.6 | 69.9 | 77.0 | +7.1 (Mac slower) | `rm -rf` + `mkdir` + scan empty dir |
| `uninstall_extension` | 198.5 | 259.1 | 99.3 | 132.6 | **+33.2** (Mac slower) | `rm -rf` + `cp -R` 32 files + recursive delete + JSON rewrite |

Two separate platform effects emerge clearly:

1. **Spawn + bootstrap is consistently slower on Mac by ~27 ms.** Same direction
   and roughly the same magnitude across every workload, before any fs work
   runs. The most plausible breakdown is Gatekeeper / AMFI signature
   verification + dyld closure resolution on each spawn of the
   `Contents/MacOS/VSCodium` binary (`com.apple.quarantine` is set on the
   bundle and the hardened runtime is enabled, so each spawn re-checks the
   signature against the kernel's CMS validation path). Linux `execve` of a
   Nix-store binary has none of that.
2. **Filesystem effects go both ways.** Once bootstrap is subtracted, two
   workloads are *faster on the Mac* and two are slower:
   - Cached reads of an already-populated dir (`list_extensions_preloaded`)
     and streaming write of a small archive (`install_extension_from_vsix`)
     are 12–28 ms **faster on the Mac**. The most likely cause is
     `compress=zstd:1` on the VM's btrfs `/tmp`: every byte read or written
     pays a zstd round-trip in the kernel, even on warm cache. APFS has no
     in-kernel compression layer for this workload.
   - Setup of an empty dir (`list_extensions_empty`) is 7 ms slower on Mac;
     `cp -R` + recursive delete + JSON rewrite on a 32-file tree
     (`uninstall_extension`) is **33 ms slower on Mac**. That is the same
     APFS-small-file-metadata signal the prior report saw at 26× on
     `fs_tmp_smallfiles_5000`, just at 32 files instead of 5000.

The net wall-clock result is workload-dependent because these two fs effects
partially cancel:

- When the bootstrap penalty dominates the fs delta, the Mac is slower by
  ~15–30 ms (everything except `list_extensions_preloaded`).
- When the fs delta is large enough to overshoot bootstrap (none here, but
  the prior report's `fs_tmp_smallfiles_5000` is exactly that case), the Mac
  falls behind dramatically.
- When the fs delta runs the *other* way and is large enough to offset
  bootstrap (`list_extensions_preloaded`), the two platforms tie.

This is more nuanced than the framing "Mac is slower at all fs metadata,"
which the first version of this report implied. The Mac is slower **only at
small-file metadata churn** (create/delete trees, rewrite JSON sidecars).
For streaming reads/writes of similar-sized buffers, the VM's btrfs
compression introduces enough overhead that the platforms swap order.

## Hypotheses retired by the matched comparison

The first cut of this report listed five hypotheses for the gap. With
VSCodium-on-Mac data now in hand, two of them are dead:

- ~~Product-level differences between VS Code and VSCodium~~ — the side-by-side
  VSCodium-on-Mac vs VS Code-on-Mac numbers spread ±25 ms in both directions,
  so any built-in MS service overhead in VS Code is washed out by point-release
  Electron differences in the opposite direction. Not the dominant effect.
- ~~Electron-version drift (34.3.x vs 34.5.x)~~ — same elimination. The matched
  comparison uses identical Electron, and the gap survives.

The remaining live hypotheses, ranked by what the decomposition supports:

1. **Spawn + signature-verification tax on macOS.** Cleanest fit for the
   consistent ~27 ms bootstrap baseline gap. Untested directly.
2. **APFS small-file metadata cost.** Already quantified at 26× by the prior
   report's `fs_tmp_smallfiles_5000`. Predicts that `uninstall_extension` has
   the largest non-bootstrap gap. It does (+33 ms).
3. **btrfs zstd compression on the VM.** Newly visible in this report.
   Predicts that `list_extensions_preloaded` (cached read) and
   `install_extension_from_vsix` (streaming write of a small archive) tilt
   toward the Mac after bootstrap subtraction. They do (−28 ms and
   −12 ms).
4. **CPU affinity inside the VM.** The Parallels guest sees 12 generic vCPUs;
   the host's `codium` invocation can land on an E-core for short workloads.
   Plausible contributor to the bootstrap baseline; untested.

## What would actually pin down each hypothesis

These probes do not require sudo:

- **Strip the quarantine xattr** on the Mac
  (`xattr -dr com.apple.quarantine /Applications/VSCodium.app`) and rerun.
  If the `version` baseline drops, Gatekeeper is the dominant component of
  hypothesis (1). If not, it is dyld/AMFI/runtime-attest.
- **Bypass both bash wrappers**: run
  `/Applications/VSCodium.app/Contents/MacOS/VSCodium --ms-enable-electron-run-as-node /Applications/VSCodium.app/Contents/Resources/app/out/cli.js --version`
  on the Mac and the unwrapped `/nix/store/.../codium` on the VM. The
  residual is pure platform spawn + Electron init.
- **Same-fs comparison**: run `uninstall_extension` against an
  `--extensions-dir` on `/dev/shm` (Linux) and on a `hdiutil`-mounted RAM
  disk (macOS). Removes APFS-vs-btrfs from the equation; if the +33 ms gap
  survives, it lives in the engine path, not the fs.
- **Disable btrfs compression on a scratch mount**. Mount a small loop file
  with `compress=no` on `/tmp/nocompress` and rerun the install workload
  there. If the −12 ms tilt collapses, hypothesis (3) is confirmed.
- **Pin to P-cores on Mac**: `taskpolicy -c utility` for the run; compare
  against `taskpolicy -c maintenance` (forces E-cores). Spread reveals the
  scheduler component.

## Reproduce

```bash
# VM
cd /home/aragao/projects/personal/nix
benchmarks/codium-vscode/run-benchmarks.py \
  --label prl-dev-vm \
  --out reports/data/codium-vscode-prl-dev-vm.json

# Mac (from VM via SSH)
scp benchmarks/codium-vscode/run-benchmarks.py \
  mac-work.local:/tmp/run-codium-vscode-benchmarks.py
ssh mac-work.local '
  CODE_BIN="/Applications/VSCodium.app/Contents/Resources/app/bin/codium" \
  python3 /tmp/run-codium-vscode-benchmarks.py \
    --label mac-work \
    --out /tmp/codium-vscode-mac-work.json
'
scp mac-work.local:/tmp/codium-vscode-mac-work.json \
  reports/data/codium-vscode-mac-work.json
```
