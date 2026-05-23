# Terminal emulator benchmarks — prl-dev-vm

Comparison of **foot**, **kitty**, **alacritty**, **ghostty**, and **xterm** on
`prl-dev-vm` (NixOS `aarch64-linux` under Parallels).

Raw hyperfine output is in
[`reports/data/terminal-emulators-prl-dev-vm.json`](./data/terminal-emulators-prl-dev-vm.json).

Harness scripts:

- [`scripts/term-bench.sh`](../scripts/term-bench.sh) — run all suites and refresh JSON
- [`scripts/term-startup-bench.sh`](../scripts/term-startup-bench.sh) — startup only
- [`scripts/term-scroll-bench.sh`](../scripts/term-scroll-bench.sh) — scroll only

## Environment

| Field | Value |
|---|---|
| Host | `prl-dev-vm` |
| When (UTC) | 2026-05-23T04:14:42Z |
| Platform | Linux 7.0.9 aarch64 (Parallels VM) |
| Display | Wayland `wayland-1`, X11 `DISPLAY=:0` |
| Font | CaskaydiaMono Nerd Font 10pt |
| Runs per test | 8 (warmup 1) |

Versions:

| Terminal | Version |
|---|---|
| foot | 1.25.0 |
| kitty | 0.44.0 |
| alacritty | 0.16.1 |
| ghostty | 1.3.1 |
| xterm | XTerm 403 (via nixpkgs when not on PATH) |

## Methodology

All tests use the **same fair rules**:

1. **Kill every terminal process** before each hyperfine run (no daemon reuse).
2. **kitty:** `--override single_instance=false`
3. **ghostty:** `--gtk-single-instance=false`
4. **xterm:** explicit `-fa 'CaskaydiaMono Nerd Font' -fs 10`, X11 path

### Startup

Cold process, one new window, inner command `true`, exit when it finishes.

### Scroll (cat / bat)

Stream a **100 000-line** file (~589 KB) to the terminal so it must paint every
line. Plain `cat` and `bat --paging=never --color=always`. This measures output
throughput, not interactive pager key-scroll (nvim batch mode was rejected as
unreliable — it often skips real TUI redraws).

## Results

Lower is better. Times are hyperfine means in milliseconds.

### Cold startup (single process, new window)

| Terminal | Mean [ms] | Min | Max |
|---|---:|---:|---:|
| **foot** | **333** | 331 | 336 |
| xterm | 351 | 346 | 355 |
| alacritty | 395 | 378 | 417 |
| kitty | 445 | 439 | 451 |
| ghostty | 884 | 871 | 890 |

**Winner: foot** (~1.05× xterm, ~1.18× alacritty, ~1.33× kitty, ~2.65× ghostty).

### Scroll — `cat` (100k lines)

| Terminal | Mean [ms] | Min | Max |
|---|---:|---:|---:|
| **foot** | **391** | 380 | 399 |
| alacritty | 441 | 422 | 456 |
| xterm | 449 | 444 | 461 |
| kitty | 624 | 607 | 653 |
| ghostty | 903 | 887 | 920 |

**Winner: foot** (~1.13× alacritty, ~1.15× xterm, ~1.60× kitty, ~2.31× ghostty).

### Scroll — `bat` (100k lines, highlighted)

| Terminal | Mean [ms] | Min | Max |
|---|---:|---:|---:|
| **foot** | **578** | 570 | 589 |
| alacritty | 610 | 593 | 626 |
| kitty | 786 | 773 | 823 |
| xterm | 1054 | 1009 | 1076 |
| ghostty | 1061 | 1013 | 1154 |

**Winner: foot** (~1.06× alacritty, ~1.36× kitty, ~1.8× xterm/ghostty).

## Takeaways on this VM

- **foot** wins every category here — fast startup and the best scroll paint
  throughput.
- **alacritty** is consistently second for startup and scroll.
- **kitty** is the flake's configured VM daily driver (Ghostty needs newer GL
  than the Parallels guest provides); it sits mid-pack on these metrics.
- **ghostty** is slow on this VM because it runs through **Mesa llvmpipe**
  (software OpenGL) per `home/desktop/ghostty.nix`.
- **xterm** startup is competitive with foot, but **bat** highlighting on X11
  is much slower than the native Wayland emulators.

## Reproduce

```bash
./scripts/term-bench.sh
# or individually:
./scripts/term-startup-bench.sh
LINES=100000 ./scripts/term-scroll-bench.sh
```
