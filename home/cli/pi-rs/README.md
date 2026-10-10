# pi-rs 0.3

A local Rust toolbox for compact command output and Pi coding tools. The
compression wrappers originated in RTK v0.40; the AST support originated in
oh-my-pi. This fork is maintained independently. See [NOTICE](NOTICE) for exact
reviewed revisions, licenses and grammar patches.

## Choose a focused query first

Use native `rg`, `jq`, or Git paths and explicit formats when the query is
already narrow. Broad build/test/log commands benefit most from compression.
Small output stays intact when a summary plus recovery hint would be larger.

```sh
pi-rs cargo test --workspace
pi-rs pytest tests/
pi-rs git log --max-count=50
pi-rs git diff -- src/
pi-rs log service.log
pi-rs grep -F -e 'critical.timeout' -p src -C 2
pi-rs read config.txt --from 240 --lines 30
pi-rs read service.log --grep 'ERROR|WARN' -C 2
pi-rs json response.json --pointer /records/250
pi-rs json response.json --pointer /records --where '/status="failed"'
pi-rs json response.json --structure
```

Search and summary emit plain text by default. Pi extensions explicitly pass
`--json` for `{content,details}` and request their own context. Search defaults
to zero context; pagination uses a deterministic sequence across sorted files.
`--per-file-cap` controls the number selected from each file per round, without
discarding later matches. `--max-columns 0` disables line-width clipping.
Paths are files or directories; expand shell globs before invoking the CLI.

`ls` emits sorted names; `--details` opts into grouping and directory counts.
Git no longer inserts a history limit or changes the log format. Status defaults
to `--short`. Large patch summaries retain changed lines, paths and hunks;
paired key/value changes include the previous value. The exact patch is saved.
JSON array summaries show endpoints, distinct shapes and representatives of
uncommon categorical values. This is a sample, not an exhaustive anomaly
analysis; use pointers, `--where`, `--full`, or native `jq` for exact questions.

## Recovery and output limits

The default budget is 32,000 UTF-8 bytes, including omission notices and
recovery paths. Set `--max-output-bytes N` before the subcommand or set
`PI_RS_MAX_OUTPUT_BYTES`. Moderate files remain whole even with many lines.

Changed or truncated command output includes `full output: PATH`. The original
combined stream is stored before filtering. Recover the stored output instead
of repeating an expensive command:

```sh
pi-rs read PATH --grep 'failure|warning' -C 3
pi-rs recall HASH_PREFIX --from 100 --lines 40
pi-rs read PATH --full
```

Recovery files may be gzip. `read` transparently decodes them and verifies
content-addressed names. Identical output shares one file. Cache files are
private (0600), published atomically and retained for at most 30 days, 200 files
and 64 MiB of stored data. Retention runs when saving output. Configure with
`PI_RS_RECOVERY_MAX_DAYS`, `PI_RS_RECOVERY_MAX_FILES` and
`PI_RS_RECOVERY_MAX_BYTES`; zero disables storage. Recovery is a cache and may
expire. Storage failure returns original output, even above the requested
output budget. Explicit projections (structure, ranges, pointers) intentionally
select different content; a JSON structure view may expand a tiny input.

## Live and machine output

```sh
pi-rs --stream cargo test -- --nocapture
pi-rs proxy sh -c 'some-command'
pi-rs docker logs --follow container
```

`--stream` forwards native arguments, stdin, stdout and stderr before any
wrapper transformations. Follow/watch, interactive and long-running modes
stream automatically; other broad commands buffer until exit to summarize.
Captured stdout/stderr share one OS pipe, preserving the order of writes into
that pipe. The child controls its own buffering. Native machine formats and
Git global options bypass compression. Nonzero statuses propagate; Unix
signals are represented as shell statuses `128 + signal`.

## Build and verify

The root `rust-toolchain.toml` pins Rust 1.99.0. The flake's `rust-toolchain`
package and development packages use the same rust-overlay toolchain as pi-rs.
All 78 direct crates were checked against stable registry releases on 2026-10-09.
The lockfile also updates transitive dependencies to current compatible releases.
Current upstream packages still require older major lines of getrandom, syn,
r-efi, redox_syscall, wasi and windows-link; the implementation report records
the exact dependents and version requirements. The three local grammar
manifest patches and their unchanged parsers are documented in NOTICE.

```sh
nix build .#rust-toolchain .#pi-rs
cargo test --workspace --manifest-path home/cli/pi-rs/Cargo.toml
cargo clippy --workspace --all-targets --manifest-path home/cli/pi-rs/Cargo.toml -- -D warnings
```

Building the toolchain does not activate a host configuration. Activate the
updated development packages through the normal NixOS/Home Manager rebuild.
The comparison requirements and verification evidence are in
[the implementation report](../../../reports/pi-rs-improvements.md).
