{
  config,
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3.withPackages (pythonPkgs: [ pythonPkgs.json5 ]);
in
{
  # Keep the ownership-aware legacy hook retirement activation so former
  # legacy-Herdr hosts cleanly drop dangling Codex/OpenCode/Pi hook entries
  # after activation without touching unrelated user preferences.
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
          --retire-legacy
      '';

  # Stop the retired agent-hub user unit if it is still running from an earlier
  # generation; Home Manager removes the managed unit and symlink files.
  home.activation.retireAgentHub = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (
    lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop agent-hub.service >/dev/null 2>&1 || true
      fi
    ''
  );
}
