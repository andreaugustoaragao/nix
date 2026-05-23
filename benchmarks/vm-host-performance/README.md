# VM vs macOS performance benchmark harness

This directory contains the non-sudo benchmark harness used by
[`../../reports/vm-vs-macos-performance.md`](../../reports/vm-vs-macos-performance.md).

The suite is intentionally simple and portable across:

- `prl-dev-vm`: NixOS / `aarch64-linux` under Parallels
- `mac-work`: nix-darwin / `aarch64-darwin` on the Apple Silicon host

It avoids `sudo`, `strace`, `dtruss`, `fs_usage`, and other privileged probes.

## Run on the VM

```bash
cd /home/aragao/projects/personal/nix
benchmarks/vm-host-performance/run-benchmarks.py \
  --repo /home/aragao/projects/personal/nix \
  --label prl-dev-vm \
  --out reports/data/vm-host-performance-prl-dev-vm.json
```

## Run on the macOS host

From the VM, assuming `mac-work` SSH is available:

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

`LIBICONV_LIB` is needed for the cached `cargo check` workload on Darwin when
using this Nix-provided Rust toolchain; without it, linking a proc-macro can
fail with `ld: library not found for -liconv`.

## Workloads

The suite measures wall-clock time for:

- clean Neovim startup + quit
- configured Neovim startup + quit
- configured Neovim open `home/cli/nvim-lazyvim.nix` + quit
- ripgrep over this repo
- Nix evaluation of `prl-dev-vm` systemd service names
- OpenSSL SHA-256 over a cached 1 GiB file
- Python integer-loop CPU work
- Python allocation/page-touch work
- sequential write/fsync/read in `/tmp`
- tiny-file create/stat/read/delete in `/tmp`
- cached `cargo check` in `home/cli/pi-rs`

All workload timings are in seconds in the raw JSON. The report renders them as
milliseconds and computes winner ratios.

## Full rebuild one-shots

The report also includes one-shot full rebuild data captured separately in
`reports/data/vm-host-full-build-*.json`:

- full `pi-rs` Cargo release rebuild with an empty `CARGO_TARGET_DIR`
- full native Nix system toplevel build/realization with `nix build --no-link`

Those rebuild commands are not part of this repeated microbenchmark harness
because they are longer, more cache-sensitive, and target different native system
outputs on VM vs macOS.
