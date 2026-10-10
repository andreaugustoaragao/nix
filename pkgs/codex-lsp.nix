{
  lib,
  callPackage,
  formats,
  writeShellApplication,
  coreutils,
  go,
  gopls,
  nodejs,
  typescript,
  typescript-language-server,
  nil,
}:

let
  lspi = callPackage ./lspi.nix { };
  rustToolchain = callPackage ./rust-toolchain.nix { };
  # typescript-language-server only publishes diagnostics when the client
  # advertises support. lspi 0.2's defaults omit this capability.
  clientCapabilities = {
    workspace = {
      workspaceFolders = true;
      configuration = true;
      workspaceEdit.documentChanges = true;
    };
    textDocument = {
      documentSymbol.hierarchicalDocumentSymbolSupport = true;
      publishDiagnostics = {
        relatedInformation = true;
        versionSupport = true;
      };
      callHierarchy.dynamicRegistration = true;
    };
    window.workDoneProgress = true;
    experimental.serverStatusNotification = true;
  };
  generic = id: extensions: languageId: command: args: {
    inherit
      id
      extensions
      command
      args
      ;
    kind = "generic";
    client_capabilities = clientCapabilities;
    language_id = languageId;
    initialize_timeout_ms = 30000;
    request_timeout_ms = 30000;
    warmup_timeout_ms = 200;
    idle_shutdown_ms = 300000;
  };
  typescriptServer =
    id: extensions: languageId:
    (generic id extensions languageId (lib.getExe typescript-language-server) [ "--stdio" ])
    // {
      adapter = "tsserver";
      # Initial project loading can briefly resolve imports to aliases only.
      warmup_timeout_ms = 1000;
      # Use the workspace's TypeScript when present; keep an offline fallback.
      initialize_options.tsserver.fallbackPath = "${typescript}/lib/node_modules/typescript/lib/tsserver.js";
    };
  lspConfig = (formats.toml { }).generate "codex-lsp.toml" {
    mcp = {
      read_only = false;
      output = {
        max_total_chars_default = 16000;
        max_total_chars_hard = 64000;
      };
      tools.allow = [
        "get_document_symbols"
        "search_workspace_symbols"
        "hover_at"
        "find_definition_at"
        "find_references_at"
        "find_implementation_at"
        "find_type_definition_at"
        "get_diagnostics"
        "rename_symbol"
        "get_server_status"
        "restart_server"
      ];
    };
    servers = [
      (generic "go" [ "go" ] "go" (lib.getExe gopls) [ "serve" ])
      {
        id = "rust";
        kind = "rust_analyzer";
        extensions = [ "rs" ];
        command = "${rustToolchain}/bin/rust-analyzer";
        initialize_timeout_ms = 30000;
        request_timeout_ms = 30000;
        warmup_timeout_ms = 1000;
        idle_shutdown_ms = 300000;
      }
      (generic "nix" [ "nix" ] "nix" (lib.getExe nil) [ ])
      (typescriptServer "typescript" [ "ts" "mts" "cts" ] "typescript")
      (typescriptServer "tsx" [ "tsx" ] "typescriptreact")
      (typescriptServer "javascript" [ "js" "mjs" "cjs" ] "javascript")
      (typescriptServer "jsx" [ "jsx" ] "javascriptreact")
    ];
  };
in
writeShellApplication {
  name = "codex-lsp";
  runtimeInputs = [
    lspi
    coreutils
  ];
  text = ''
    # Keep project-selected toolchains first, with Nix-managed fallbacks for
    # desktop clients and minimal shells. LSP executables are pinned above.
    export PATH="$PATH:${
      lib.makeBinPath [
        rustToolchain
        go
        nodejs
        typescript
      ]
    }"

    root="$PWD"
    scan="$PWD"
    manifest_root=""
    while true; do
      if [[ -e "$scan/.git" ]]; then
        root="$scan"
        break
      fi
      if [[ -z "$manifest_root" ]] &&
        [[ -f "$scan/go.work" || -f "$scan/go.mod" || -f "$scan/Cargo.toml" ||
           -f "$scan/tsconfig.json" || -f "$scan/package.json" || -f "$scan/flake.nix" ]]; then
        manifest_root="$scan"
      fi
      if [[ "$scan" == / ]]; then
        root="''${manifest_root:-$PWD}"
        break
      fi
      scan="$(dirname "$scan")"
    done

    mode=mcp
    if [[ "''${1:-}" == doctor ]]; then
      mode=doctor
      shift
    fi
    exec ${lib.getExe lspi} "$mode" --workspace-root "$root" --config ${lspConfig} "$@"
  '';
}
