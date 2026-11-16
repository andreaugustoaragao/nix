{
  config,
  lib,
  pkgs,
  unstable-pkgs,
  ...
}:

let
  # pi-rs token-compression binary + materialized shim scripts.
  # preToolUse hook routes Shell commands through `pi-rs hook cursor`.
  piRs = pkgs.callPackage ./pi-rs { };
  agents = pkgs.callPackage ../../pkgs/agent-binaries { };
  codeLsp = pkgs.callPackage ../../pkgs/codex-lsp.nix {
    inherit (unstable-pkgs) go gopls;
    textFallback = true;
  };
  codeToolsFiles = pkgs.linkFarm "nix-code-tools-files" [
    {
      name = ".cursor-plugin/plugin.json";
      path = pkgs.writeText "plugin.json" (
        builtins.toJSON {
          name = "nix-code-tools";
          version = "1.0.0";
          description = "Managed code intelligence";
          mcpServers = "./mcp.json";
        }
      );
    }
    {
      name = "mcp.json";
      path = pkgs.writeText "mcp.json" (
        builtins.toJSON {
          mcpServers.lsp = {
            command = lib.getExe codeLsp;
            args = [ ];
          };
        }
      );
    }
    {
      name = "rules/tools.mdc";
      path = pkgs.writeText "tools.mdc" ''
        ---
        alwaysApply: true
        ---
        Use native read_lints for supported diagnostics. Use the lsp MCP
        for definitions, references, types, symbols and Go/Rust/Nix diagnostics.
        Positions are 1-based; rename defaults to preview. If a server fails,
        inspect get_server_status and restart once, then use compiler/CLI checks.
        Prefer focused rg for known text and project checks to verify changes.

        Check source, types and bundled docs before external documentation.
        Use Context7 only when available and unresolved version-specific API
        behavior affects the task; request one focused answer for that version.

        ${builtins.readFile ./pi-rs/agent-hooks/codex-rules.md}
      '';
    }
  ];
  # Cursor's plugin discovery skips component symlinks outside the plugin root.
  codeTools = pkgs.runCommand "nix-code-tools" { } ''
    mkdir -p "$out"
    cp -rL ${codeToolsFiles}/. "$out/"
  '';
  cursorAgent = pkgs.writeShellScript "cursor-agent" ''
    exec ${agents.cursor-agent}/bin/cursor-agent --plugin-dir ${codeTools} "$@"
  '';
  agentHubHooks =
    lib.optional config.my.agentHarness.agentHub.enable {
      command = "${lib.getExe (pkgs.callPackage ../../pkgs/agent-hub.nix { })} cursor-hook";
    }
    ++ lib.optional (!config.my.agentHarness.agentHub.enable) {
      command = ''if [ -x "${config.home.homeDirectory}/.local/bin/agent-hub" ]; then "${config.home.homeDirectory}/.local/bin/agent-hub" cursor-hook; else printf '{}\n'; fi'';
    };
  # Cursor / cursor-agent reads ~/.cursor/hooks.json for hook registration.
  # The format mirrors Claude Code's hook config in spirit: a list of
  # event entries, each with a matcher and a command to invoke.
  #
  # The `pi-rs hook cursor` adapter writes the agent-expected envelope
  # (`{"permission":"allow","updated_input":{"command":...}}` on rewrite,
  # `{}` on passthrough). See home/cli/pi-rs/crates/pi-rs/src/cmd/hook.rs.
  hooksData = {
    version = 1;
    hooks = {
      sessionStart =
        agentHubHooks
        ++ lib.optional config.my.agentHarness.legacyHerdr {
          command = "bash '${config.home.homeDirectory}/.cursor/herdr-agent-state.sh' session";
        };
      sessionEnd = agentHubHooks;
      beforeSubmitPrompt = agentHubHooks;
      afterAgentResponse = agentHubHooks;
      postToolUse = agentHubHooks;
      stop = map (hook: hook // { loop_limit = 1; }) agentHubHooks;
      preToolUse = [
        {
          matcher = "Shell";
          command = "${piRs}/share/pi-rs/agent-hooks/cursor-rewrite.sh";
        }
      ]
      ++ agentHubHooks;
    };
  };
  hooks = pkgs.writeText "cursor-hooks.json" (builtins.toJSON hooksData);
  configureHooks = arguments: ''
    run ${lib.getExe pkgs.python3} ${./agent-json-configure.py} \
      --kind cursor \
      --target ${lib.escapeShellArg "${config.home.homeDirectory}/.cursor/hooks.json"} \
      --desired ${hooks} \
      --state ${lib.escapeShellArg "${config.xdg.stateHome}/agent-json/cursor.json"} \
      --legacy "''${oldGenPath:-}/home-files/.cursor/hooks.json" ${arguments}
  '';
in
{
  home.file = lib.genAttrs [ ".local/bin/cursor-agent" ".local/bin/agent" ] (_: {
    source = cursorAgent;
    force = true;
  });
  my.agentHarness.cursorHooks = hooksData;
  home.activation.cursorHooksPrepare =
    lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ]
      (configureHooks "--prepare");
  home.activation.cursorHooks = lib.hm.dag.entryAfter [ "linkGeneration" ] (configureHooks "");

  # cursor-agent stores runtime state (model picker, auth) in
  # ~/.cursor/cli-config.json. Merge requested defaults on activation so we do not
  # overwrite fields the CLI manages itself.
  home.activation.cursorCliConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="${config.home.homeDirectory}/.cursor/cli-config.json"
    mkdir -p "$(dirname "$target")"
    if [[ -f "$target" ]]; then
      existing="$(cat "$target")"
    else
      existing='{"permissions":{"allow":[],"deny":[]},"version":1}'
    fi
    printf '%s' "$existing" \
      | ${pkgs.jq}/bin/jq '
          .editor = ((.editor // {}) + {vimMode: true})
          | .approvalMode = "unrestricted"
          | .autoAcceptWebSearch = true
          | .sandbox = ((.sandbox // {}) + {mode: "disabled"})
        ' \
      > "$target.tmp"
    mv "$target.tmp" "$target"
    chmod 0600 "$target"
  '';
}
