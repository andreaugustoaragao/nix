# VM vs macOS performance investigation

This report compares developer-workload performance between:

- **VM:** `prl-dev-vm`, NixOS `aarch64-linux` running under Parallels
- **Host:** `mac-work`, nix-darwin `aarch64-darwin` running directly on Apple Silicon

The goal is not to prove that one system is universally faster. The goal is to
identify which workload classes favor the VM, which favor native macOS, and what
causes plausibly explain the differences.

Raw results are checked in under [`reports/data/`](./data/):

- [`vm-host-performance-prl-dev-vm.json`](./data/vm-host-performance-prl-dev-vm.json)
- [`vm-host-performance-mac-work.json`](./data/vm-host-performance-mac-work.json)
- [`vm-host-full-build-prl-dev-vm.json`](./data/vm-host-full-build-prl-dev-vm.json)
- [`vm-host-full-build-mac-work.json`](./data/vm-host-full-build-mac-work.json)

The non-sudo benchmark harness is in
[`benchmarks/vm-host-performance/`](../benchmarks/vm-host-performance/).

## Executive summary

The result is workload-dependent:

- The **Linux VM is much faster** for short-lived developer tools and
  metadata-heavy operations:
  - Neovim launch/open/close
  - repo search with `ripgrep`
  - tiny-file create/stat/read/delete
  - cached Rust `cargo check`
- The **macOS host is faster** for:
  - memory allocation/page touching
  - sequential write/read in `/tmp`
  - Python integer-loop interpreter work, slightly
- CPU crypto was close, with the VM slightly ahead in this pass.

The strongest pattern is:

> Linux-in-VM has substantially lower overhead for short-lived developer tools
> and metadata-heavy filesystem workloads than macOS/APFS/Nix-on-Darwin, while
> native macOS has better raw memory/page-fault behavior and somewhat better
> sequential filesystem throughput.

## Environment

| Dimension | VM | macOS host |
|---|---|---|
| Hostname | `prl-dev-vm` | `G7CH2W2XYR` / `mac-work` |
| OS | NixOS Linux `7.0.9` | macOS `26.5`, Darwin `25.5.0` |
| Architecture | `aarch64-linux` | `aarch64-darwin` |
| Virtualization | Parallels | Native host |
| CPU visible to OS | 12 generic ARM vCPUs | Apple M5 Max, 18 CPUs |
| Host core topology | Hidden from guest | 6 performance + 12 efficiency cores |
| RAM visible | ~64 GiB | 128 GiB |
| Neovim | `NVIM v0.12.2` | `NVIM v0.12.2` |
| OpenSSL | `3.6.2` | `3.6.2` |
| Python | `3.13.12` | `3.13.12` |
| Rust | `rustc 1.91.1`, `cargo 1.91.0` | Same |
| ripgrep | `15.1.0` | `15.1.0` |
| Nix | `2.31.5` | `2.31.5` |

Important VM filesystem details:

- VM root, `/nix`, `/home`, and `/tmp` are Btrfs subvolumes.
- Mount options include `compress=zstd:1`, `noatime`, `discard=async`, and
  `space_cache=v2`.
- `/nix/store` is mounted read-only over the same Btrfs-backed `/nix` subvolume.

Important host filesystem detail:

- The macOS host uses APFS.
- The repo is under `/Users/aragao/projects/personal/nix`.

## Main results

Lower is better for every row.

| Category | Workload | VM | macOS host | Winner | Ratio |
|---|---|---:|---:|---|---:|
| Editor/process | Neovim clean startup and immediate quit | **6.1 ms ± 0.3** | 27.6 ms ± 1.5 | VM | **4.52×** |
| Editor/process | Configured Neovim startup and immediate quit | **23.5 ms ± 0.8** | 58.4 ms ± 2.6 | VM | **2.48×** |
| Editor/file open | Configured Neovim opens `home/cli/nvim-lazyvim.nix` and quits | **69.3 ms ± 8.8** | 112.3 ms ± 24.0 | VM | **1.62×** |
| Search/metadata | `ripgrep` over repo for NixOS/VM/editor/systemd terms | **4.4 ms ± 0.7** | 21.0 ms ± 1.3 | VM | **4.76×** |
| CPU/crypto | OpenSSL hashes cached 1 GiB file with SHA-256 | **367.9 ms ± 1.1** | 400.3 ms ± 2.8 | VM | **1.09×** |
| CPU/interpreter | Python integer loop, 15M iterations | 1227.9 ms ± 29.3 | **1156.1 ms ± 13.2** | macOS | **1.06×** |
| Memory/page faults | Python allocates and touches 512 MiB bytearray | 97.1 ms ± 3.4 | **47.8 ms ± 0.3** | macOS | **2.03×** |
| Filesystem/sequential | Write + fsync + read 512 MiB file in `/tmp` | 107.4 ms ± 21.1 | **80.6 ms ± 1.6** | macOS | **1.33×** |
| Filesystem/metadata | Create/stat/read/delete 5k tiny files in `/tmp` | **54.7 ms ± 1.7** | 1433.0 ms ± 32.1 | VM | **26.22×** |
| Dev/Rust | Cached `cargo check` for `home/cli/pi-rs` | **45.6 ms ± 1.6** | 515.0 ms ± 13.4 | VM | **11.30×** |

## Full rebuild results

These are one-shot full rebuild measurements rather than repeated microbenchmarks.
The Rust rebuild used an empty `CARGO_TARGET_DIR` on each machine. The Nix build
realized each machine's native system toplevel without switching it:

- VM: `.#nixosConfigurations.prl-dev-vm.config.system.build.toplevel`
- macOS host: `.#darwinConfigurations.mac-work.config.system.build.toplevel`

| Category | Workload | VM | macOS host | Winner | Ratio |
|---|---|---:|---:|---|---:|
| Dev/Rust/full build | Full `pi-rs` Cargo release rebuild with empty target dir | **25.653 s** | 32.322 s | VM | **1.26×** |
| Nix/full build | Full native system toplevel build/realization, no switch | **20.359 s** | 20.853 s | VM | **1.02×** |

The full Rust rebuild narrows the huge cached-`cargo check` gap because real
compilation dominates more of the run. The VM still wins, but by a modest 1.26×
instead of 11.30×.

The full native Nix build is effectively tied in this pass. Both systems likely
benefited from existing store paths/substituter cache; this measurement is best
read as "realization of the current native system closure" rather than a fully
cold build from source.

## Interpretation by workload

### Neovim startup/open/close

The VM wins decisively.

| Neovim workload | VM | macOS | VM advantage |
|---|---:|---:|---:|
| `nvim --clean --headless +qa` | 6.1 ms | 27.6 ms | 4.52× |
| Configured `nvim --headless +qa` | 23.5 ms | 58.4 ms | 2.48× |
| Configured open file + quit | 69.3 ms | 112.3 ms | 1.62× |

The clean baseline shows that the macOS side has substantially higher process
startup, dynamic loading, runtime initialization, Nix wrapper, or filesystem path
traversal overhead before user configuration even matters.

The configured startup result shows the same direction after loading the real
Neovim configuration. Opening `home/cli/nvim-lazyvim.nix` narrows the gap because
both systems spend more time doing editor/filetype work, but the VM still wins.

Likely causes:

- Nix-on-Darwin wrapper and dynamic linker overhead.
- APFS metadata/path traversal overhead across many Nix store paths and runtime
  files.
- macOS process creation and security checks.
- Linux page cache and Btrfs metadata behavior being favorable for this workload.

### Search / metadata-heavy CLI work

`ripgrep` over the repo:

- VM: **4.4 ms**
- macOS: **21.0 ms**
- VM advantage: **4.76×**

This aligns with the Neovim startup result. Short-lived developer tools that walk
repo and Nix-store metadata are much cheaper in the VM.

Likely causes:

- APFS metadata overhead.
- Nix store path fan-out on Darwin.
- macOS syscall/security overhead.
- Linux page cache and Btrfs metadata path performing better for this repo.

### CPU crypto

OpenSSL SHA-256 over a cached 1 GiB file:

- VM: **367.9 ms**
- macOS: **400.3 ms**
- VM advantage: **1.09×**

This is close enough to treat as broadly comparable rather than a decisive VM
win. The workload still includes file reads from cache, so it is not a pure CPU
microbenchmark.

Possible causes for the small VM edge:

- Different kernel file-read path.
- Different scheduling of the workload onto host cores.
- Slightly different interaction between OpenSSL, libc, and the OS read path.

### Python interpreter CPU

Python integer loop:

- VM: **1227.9 ms**
- macOS: **1156.1 ms**
- macOS advantage: **1.06×**

This is a small native-host win.

Likely causes:

- Native macOS can schedule directly onto Apple performance cores.
- The VM sees 12 generic vCPUs and does not expose Apple P/E topology.
- Parallels decides how guest vCPU execution maps onto host cores.

### Memory allocation / page faults

Python allocate-and-touch 512 MiB bytearray:

- VM: **97.1 ms**
- macOS: **47.8 ms**
- macOS advantage: **2.03×**

This is one of the clearest host wins.

Likely causes:

- VM second-stage address translation overhead.
- Guest page faults require coordination between the guest kernel, hypervisor,
  and host memory manager.
- Native macOS can back and zero pages directly.

### Sequential filesystem throughput

Write + fsync + read 512 MiB in `/tmp`:

- VM: **107.4 ms**
- macOS: **80.6 ms**
- macOS advantage: **1.33×**

This matches expectations: native APFS on Apple storage is a shorter path than
VM userspace → guest Linux VFS → Btrfs → Parallels virtual block device → host
APFS backing file → physical storage.

### Tiny-file metadata workload

Create/stat/read/delete 5k tiny files in `/tmp`:

- VM: **54.7 ms**
- macOS: **1433.0 ms**
- VM advantage: **26.22×**

This is the largest measured delta and is probably central to why interactive
dev workflows can feel faster inside the VM.

Likely causes:

- APFS is expensive for massive tiny-file create/delete workloads.
- macOS adds metadata, extended attribute, security, and filesystem bookkeeping
  overhead.
- Linux/Btrfs with `noatime` and hot cache is very fast for this pattern.
- The VM virtual disk layer is not the bottleneck here; metadata behavior
  dominates.

### Cached Rust dev workload

Cached `cargo check` in `home/cli/pi-rs`:

- VM: **45.6 ms**
- macOS: **515.0 ms**
- VM advantage: **11.30×**

A cached check is not mostly raw compiler speed. It is dominated by:

- walking dependency metadata
- checking mtimes
- reading incremental state
- probing target directories
- invoking/linking small helper paths
- filesystem metadata operations

So this result fits the `ripgrep`, Neovim startup, and tiny-file metadata
results.

Note: On macOS, the benchmark sets `LIBRARY_PATH` to Nix's `libiconv` library
directory for the cached `cargo check` workload. Without that, linking a proc
macro failed with `ld: library not found for -liconv`. That is a Darwin/Nix
dev-environment difference, but the timing above was captured after providing
the needed path.

## Root-cause themes

### macOS/Nix-on-Darwin has higher short-process overhead

Supported by:

- `nvim --clean`: VM 4.52× faster
- configured `nvim`: VM 2.48× faster
- `ripgrep`: VM 4.76× faster

Likely components:

- process launch overhead
- dynamic linker behavior
- Nix wrapper/store path traversal
- APFS metadata behavior
- macOS security/code-signing checks

### APFS is costly for tiny-file churn

Supported by:

- tiny-file workload: VM 26.22× faster
- cached `cargo check`: VM 11.30× faster
- `ripgrep`: VM 4.76× faster

This appears to be one of the dominant explanations for why dev workflows can
feel faster in the VM.

### Native macOS wins memory/page-fault behavior

Supported by:

- 512 MiB allocate/touch: macOS 2.03× faster

Virtualization overhead is expected here because the VM must maintain guest
physical mappings backed by host memory.

### Native macOS wins larger sequential I/O

Supported by:

- 512 MiB write/fsync/read: macOS 1.33× faster

This matches the shorter native storage stack on the host.

### Raw CPU is close, with scheduling caveats

Supported by:

- Python integer loop: macOS 1.06× faster
- OpenSSL SHA-256: VM 1.09× faster

The CPU picture is mixed and small compared with filesystem/process differences.
The guest sees 12 generic vCPUs; the host has 6 performance and 12 efficiency
cores. Parallels' vCPU placement can materially affect CPU-bound results.

## Non-sudo attribution status

Privileged tracing was deliberately not used. The VM currently has:

```text
/proc/sys/kernel/yama/ptrace_scope = 2
```

That blocks unprivileged `strace`/ptrace-based attribution. macOS tracing tools
such as `dtruss` and `fs_usage` commonly need elevated privileges as well. Per
investigation constraints, this report does not rely on them.

The current root-cause statements are therefore based on workload signatures and
system architecture, not syscall traces.

## Reproduction

Run the VM side:

```bash
cd /home/aragao/projects/personal/nix
benchmarks/vm-host-performance/run-benchmarks.py \
  --repo /home/aragao/projects/personal/nix \
  --label prl-dev-vm \
  --out reports/data/vm-host-performance-prl-dev-vm.json
```

Run the macOS side from the VM:

```bash
scp benchmarks/vm-host-performance/run-benchmarks.py mac-work:/tmp/run-vm-host-benchmarks.py
ICONV_LIB=$(ssh mac-work 'nix eval --raw nixpkgs#libiconv.outPath')/lib
ssh mac-work \
  "LIBICONV_LIB='$ICONV_LIB' python3 /tmp/run-vm-host-benchmarks.py \
    --repo /Users/aragao/projects/personal/nix \
    --label mac-work \
    --out /tmp/vm-host-performance-mac-work.json"
scp mac-work:/tmp/vm-host-performance-mac-work.json \
  reports/data/vm-host-performance-mac-work.json
```

## Follow-up work that does not require sudo

1. Add a cold-cache-ish variant by changing filenames and data sizes between
   runs. This cannot fully drop OS caches without privileges, but it can reduce
   cache reuse.
2. Add a macOS RAM-disk or VM tmpfs comparison if a non-sudo setup is available.
3. Add real editor readiness benchmarks, such as opening a project file and
   waiting for LSP attachment rather than only process exit.
4. Compare VM vCPU counts through Parallels settings and rerun CPU/memory tests.
5. Compare Btrfs compression settings or an ext4 test volume if a non-disruptive
   test disk is available.
6. Add `bun install/build`, `node` project startup, and clean Rust builds for
   fuller development workload coverage.

## Bottom line

For this developer workflow, the VM is not merely competitive; it is faster for
many interactive/editor/repo operations because those operations are dominated by
filesystem metadata and process startup overhead. Native macOS still has the
expected advantage in raw memory management and sequential storage access.

The practical rule of thumb from these measurements is:

> If the workload touches many small files or starts many short-lived Nix-managed
> tools, the Linux VM is dramatically faster. If the workload streams large files
> or allocates/touches lots of memory, native macOS tends to win.
