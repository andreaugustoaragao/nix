{
  config,
  lib,
  pkgs,
  ...
}:
let
  agents = pkgs.callPackage ../../pkgs/agent-binaries { };
  localModels = config.services.piModels.providers.llama-cpp.models or [ ];
  localModel = if localModels == [ ] then "" else "llama-cpp/${(builtins.head localModels).id}";
  piTask = pkgs.writeShellApplication {
    name = "pi-task";
    text =
      builtins.replaceStrings
        [ "@pi@" "@local-model@" ]
        [ (lib.escapeShellArg "${agents.pi}/bin/pi") (lib.escapeShellArg localModel) ]
        (builtins.readFile ./pi-task.sh);
  };
in
{
  home.packages = [
    agents.codex
    agents.pi
    piTask
    agents.cursor-agent
  ];
  home.file =
    lib.mapAttrs
      (_: source: {
        inherit source;
        force = true;
      })
      {
        ".local/bin/pi" = "${agents.pi}/bin/pi";
        ".local/bin/pi-task" = lib.getExe piTask;
      };
}
