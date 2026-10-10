# pi-rs output compression

Use focused native queries (`rg`, `jq`, Git paths/formats) when they directly
answer the question. Use `pi-rs cargo`, `pytest`, `git`, `npm`/`pnpm`/`yarn`,
`gh`, or `log FILE` for broad, noisy output. `docker`/`kubectl` wrappers also
compress logs. Exit status is preserved; explicit machine formats pass through.

`pi-rs read FILE` preserves moderate files. `--from N --lines N` selects a
source-line window, even when combined with `--grep`. To find matching lines
anywhere, use `--grep PATTERN [-F] [-C N]` without `--lines`. `grep -e PATTERN -p PATH`
defaults to plain matches; `-F` is literal, `-C` adds context, `--skip` paginates.
`json FILE --pointer /records/250` selects an exact value.

When output includes `full output: PATH`, recover that saved output with
`pi-rs read PATH --grep PATTERN` or `--full`; it may be gzip. Do not rerun an
expensive command to recover output. Recovery is bounded and may expire.
Use `pi-rs --stream TOOL ...` or `pi-rs proxy COMMAND ...` for immediate native
output. Follow/watch/interactive modes stream automatically.
