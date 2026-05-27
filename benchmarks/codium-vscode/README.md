# VSCodium / VS Code CLI benchmark harness

Companion to [`reports/codium-vscode-vm-vs-macos.md`](../../reports/codium-vscode-vm-vs-macos.md).
Same shape as `benchmarks/vm-host-performance/`: a single Python driver that
runs each workload N times under shell wall-clock and writes raw JSON for the
report.

## What it measures

Five headless CLI workloads on whichever `codium` / `code` binary you point it
at. No display server, no GUI window, runs over SSH unchanged.

- `version` — bash wrapper + Electron-as-Node bootstrap.
- `list_extensions_empty` — engine + extension-host walk over an empty
  `--extensions-dir`.
- `list_extensions_preloaded` — same against a dir with EditorConfig already
  installed.
- `install_extension_from_vsix` — install a pinned VSIX (EditorConfig 0.18.2
  from Open VSX, fetched once into a local cache) into a fresh dir.
- `uninstall_extension` — clone the preloaded dir to a scratch copy and
  uninstall.

Each run that needs a fresh state nukes its directory in the same shell line
so the cost is identical on both hosts.

## Prerequisites

- `codium` (Linux) or VS Code's `code` CLI shim under
  `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`
  (macOS).
- `python3` (no extra deps; stdlib only).
- `curl` (used once to fetch the pinned VSIX; OS trust store, not Python's).
- Network egress to `open-vsx.org` for the first run on each host.

## Run on the VM

```bash
cd /home/aragao/projects/personal/nix
benchmarks/codium-vscode/run-benchmarks.py \
  --label prl-dev-vm \
  --out reports/data/codium-vscode-prl-dev-vm.json
```

`--binary` defaults to `codium` on Linux. Override with `--binary` or
`$CODE_BIN` if you want to point at a different editor.

## Run on the macOS host (over SSH from the VM)

```bash
scp benchmarks/codium-vscode/run-benchmarks.py \
  mac-work.local:/tmp/run-codium-vscode-benchmarks.py
ssh mac-work.local '
  CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
  python3 /tmp/run-codium-vscode-benchmarks.py \
    --label mac-work \
    --out /tmp/codium-vscode-mac-work.json
'
scp mac-work.local:/tmp/codium-vscode-mac-work.json \
  reports/data/codium-vscode-mac-work.json
```

The Mac `python3` will auto-detect the VS Code `.app` path if `CODE_BIN` is
not set. Setting it explicitly keeps the JSON output traceable.

## Output

Each run writes one JSON object with:

- `metadata` — host info, Electron build info, CPU/RAM/disk summary,
  virtualization flag, code binary path.
- `results` — one entry per workload with `runs_raw` (every individual
  measurement) plus `mean` / `median` / `min` / `max` / `stdev` /
  `runs_completed`.
- `config` — VSIX URL, cache paths, work dir.

Wall-clock unit is **seconds**; the report renders milliseconds.

## Notes

- The VSIX is pinned to `EditorConfig.EditorConfig-0.18.2` from Open VSX so
  the install/uninstall workloads do not hit a network in the measured loop
  and both editors install the exact same artifact (avoids Open-VSX vs MS
  Marketplace asymmetry).
- The harness deliberately does **not** kill stray helper processes between
  runs. All workloads are short-lived headless CLI invocations that exit on
  their own; the daemon-reuse problem that the terminal-emulator harness
  guards against does not apply here.
- For GUI cold-start measurement (window-ready latency) the recommended
  approach is to add a probe extension that issues
  `workbench.action.closeWindow` on activate and time `code --wait`. That
  extension is not in this v1.
