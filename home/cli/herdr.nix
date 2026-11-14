{
  config,
  lib,
  pkgs,
  appearance,
  hostName,
  ...
}:

let
  herdr = pkgs.callPackage ../../pkgs/herdr.nix { };
  python = pkgs.python3.withPackages (pythonPkgs: [ pythonPkgs.json5 ]);
  assets = "${herdr}/share/herdr/integrations";
  # These paths are also inspected by `herdr integration status`.
  integrations = {
    ".codex/herdr-agent-state.sh" = "codex/herdr-agent-state.sh";
    ".cursor/herdr-agent-state.sh" = "cursor/herdr-agent-state.sh";
    ".grok/hooks/herdr-agent-state.sh" = "grok/herdr-agent-state.sh";
    ".pi/agent/extensions/herdr-agent-state.ts" = "pi/herdr-agent-state.ts";
  };
in
{
  home.packages = lib.optional (hostName != "prl-dev-vm") herdr;

  home.file = lib.mkIf (hostName != "prl-dev-vm") (
    lib.mkMerge [
      (lib.mapAttrs (_: asset: {
        source = "${assets}/${asset}";
        executable = lib.hasSuffix ".sh" asset;
        # Replace previous copies installed by Herdr with the same pinned assets.
        force = true;
      }) integrations)
      {
        ".grok/hooks/herdr.json" = {
          force = true;
          text = builtins.toJSON {
            hooks.SessionStart = [
              {
                hooks = [
                  {
                    type = "command";
                    command = "sh '${config.home.homeDirectory}/.grok/hooks/herdr-agent-state.sh' session";
                    timeout = 10;
                  }
                ];
              }
            ];
          };
        };
      }
    ]
  );

  xdg.configFile = lib.mkIf (hostName != "prl-dev-vm") {
    "herdr/config.toml" = {
      force = true;
      source = (pkgs.formats.toml { }).generate "herdr-config.toml" {
        onboarding = false;
        theme = lib.optionalAttrs appearance.isGruvbox {
          name = "gruvbox";
          auto_switch = true;
          dark_name = "gruvbox";
          light_name = "gruvbox-light";
        };
        update = {
          # The executable and integrations are updated together through Nix.
          version_check = false;
          manifest_check = true;
        };
        keys = {
          # Keep tmux's prefix, pane navigation, new-tab, and zoom defaults.
          split_vertical = "prefix+percent";
          split_horizontal = "prefix+double_quote";
          workspace_picker = [
            "prefix+w"
            "prefix+f"
          ];
          resize_pane_left = "prefix+shift+h";
          resize_pane_down = "prefix+shift+j";
          resize_pane_up = "prefix+shift+k";
          resize_pane_right = "prefix+shift+l";
        };
        ui = {
          agent_panel_sort = "priority";
          status_indicators = "symbols";
          toast.delivery = "system";
        };
        session.resume_agents_on_restore = true;
      };
    };
    "opencode/plugins/herdr-agent-state.js".source = "${assets}/opencode/herdr-agent-state.js";
    "opencode/herdr-tui-session.js".source = "${assets}/opencode/herdr-tui-session.js";
    "opencode/herdr-opencode/tui.js".source = "${assets}/opencode/herdr-opencode/tui.js";
  };

  # Agent-owned JSON stays writable. Merge only Herdr entries after Codex's
  # config activation, preserving other hooks, plugins, and TUI preferences.
  home.activation.herdrIntegrations =
    lib.hm.dag.entryAfter
      [
        "linkGeneration"
        "codexConfig"
      ]
      ''
        run ${lib.getExe python} ${./herdr-configure.py} \
          --home ${lib.escapeShellArg config.home.homeDirectory} \
          --config-home ${lib.escapeShellArg config.xdg.configHome} \
          --state-home ${lib.escapeShellArg config.xdg.stateHome} \
          ${lib.optionalString (hostName == "prl-dev-vm") "--retire-legacy"}
      '';
}
