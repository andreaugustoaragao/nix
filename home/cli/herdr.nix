{
  config,
  lib,
  pkgs,
  ...
}:

let
  herdr = pkgs.callPackage ../../pkgs/herdr.nix { };
  python = pkgs.python3.withPackages (pythonPkgs: [ pythonPkgs.json5 ]);
  assets = "${herdr}/share/herdr/integrations";
  skill = "${herdr}/share/herdr/skill";
  # These paths are also inspected by `herdr integration status`.
  integrations = {
    ".claude/hooks/herdr-agent-state.sh" = "claude/herdr-agent-state.sh";
    ".codex/herdr-agent-state.sh" = "codex/herdr-agent-state.sh";
    ".cursor/herdr-agent-state.sh" = "cursor/herdr-agent-state.sh";
    ".grok/hooks/herdr-agent-state.sh" = "grok/herdr-agent-state.sh";
    ".pi/agent/extensions/herdr-agent-state.ts" = "pi/herdr-agent-state.ts";
  };
  skills = [
    # Codex and Pi both discover the shared Agent Skills directory.
    ".agents/skills/herdr"
    ".claude/skills/herdr"
    ".cursor/skills/herdr"
    ".grok/skills/herdr"
    ".gemini/skills/herdr"
    ".config/opencode/skills/herdr"
  ];
in
{
  home.packages = [ herdr ];

  home.file = lib.mkMerge [
    (lib.mapAttrs (_: asset: {
      source = "${assets}/${asset}";
      executable = lib.hasSuffix ".sh" asset;
      # Replace previous copies installed by Herdr with the same pinned assets.
      force = true;
    }) integrations)
    (lib.genAttrs skills (_: {
      source = skill;
    }))
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
  ];

  xdg.configFile = {
    "herdr/config.toml" = {
      force = true;
      source = (pkgs.formats.toml { }).generate "herdr-config.toml" {
        onboarding = false;
        update = {
          # The executable and integrations are updated together through Nix.
          version_check = false;
          manifest_check = true;
        };
        session.resume_agents_on_restore = true;
      };
    };
    "opencode/plugins/herdr-agent-state.js".source = "${assets}/opencode/herdr-agent-state.js";
    "opencode/herdr-tui-session.js".source = "${assets}/opencode/herdr-tui-session.js";
    "opencode/herdr-opencode/tui.js".source = "${assets}/opencode/tui.js";
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
          --state-home ${lib.escapeShellArg config.xdg.stateHome}
      '';
}
