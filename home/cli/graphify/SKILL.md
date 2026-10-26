---
name: graphify
description: Build and query a local code relationship graph when the user asks to use Graphify for architecture or change-impact investigation.
disable-model-invocation: true
---

# Graphify

Use the Nix-installed `graphify` CLI. This skill works through the terminal in
Codex, Pi, and OpenCode; it does not require a client-specific subagent tool.

## Select the checkout

Work inside one active project checkout. Do not scan a parent directory containing
multiple repositories or divergent worktrees. Exclude dependencies, generated
code, build output, reports, and archives when they are not relevant.

Check for an existing `graphify-out/graph.json` and whether it belongs to the
current checkout and source revision. Refresh stale graphs before relying on
them. Consult `graphify --help` and the relevant subcommand's help for flags.

## Build a local code graph

Code-only extraction is the default for this installation. Run from the selected
checkout:

```sh
GRAPHIFY_BACKEND=none GRAPHIFY_MAX_WORKERS=2 graphify extract . --code-only
```

The command-scoped backend setting disables semantic model calls and automatic
model-based labels. The worker limit keeps indexing from occupying every CPU.
Do not change the user's global model environment.

To also generate the report and interactive HTML view:

```sh
GRAPHIFY_BACKEND=none graphify cluster-only .
```

## Query and verify

From the same checkout, use the graph to locate candidate source files:

```sh
GRAPHIFY_BACKEND=none graphify query "the relationship to investigate"
GRAPHIFY_BACKEND=none graphify explain "SymbolName"
GRAPHIFY_BACKEND=none graphify path "FirstSymbol" "SecondSymbol"
```

Read the relevant source and use LSP for exact definitions, references, and types.
Graph paths can be incomplete or inferred, especially across HTTP, event buses,
dynamic registration, and language boundaries. Use the project's verification
harness to establish runtime behavior. Version 0.9.95 skips `.nix` and `.qml` files.

## Optional features

Include semantic analysis of documents or media only when the user requests it.
Choose an explicit backend and account for its model usage; the local code graph
does not need an API key. Optional provider SDKs and MCP support may require
additional Nix dependencies.

Keep this installation declarative. Update the Nix configuration for package or
integration changes. Do not run `graphify install`, mutable pip/uv installs, or
automatic hook/guard setup over the managed skills and agent instructions.
