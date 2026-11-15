{
  lib,
  pkgs,
  hostName,
  isBuildWorker ? false,
  ...
}:
{
  imports = [
    ./agent-binaries.nix
    ./agent-hub.nix
    ./codex.nix
    ./pi.nix
    ./cursor.nix
    ./opencode.nix
    ./shared-vault.nix
    ./herdr.nix
    ./herdr-preview.nix
    ./agent-terminals.nix
    ./agent-projects.nix
    ./herdr-coordinate.nix
    ./pstack.nix
    ./portable-skills.nix
    ./grill-me.nix
    ./graphify.nix
  ];
  options.my.agentHarness = {
    legacyHerdr = lib.mkOption {
      type = lib.types.bool;
      default =
        !(
          builtins.elem hostName [
            "prl-dev-vm"
            "workstation"
          ]
          || isBuildWorker
        );
      description = "Retain the older Herdr TUI integrations instead of core-managed terminals.";
    };
    codexTemplate = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      description = "Actual generated Codex template used by compatibility checks.";
    };
    cursorHooks = lib.mkOption {
      inherit (pkgs.formats.json { }) type;
      readOnly = true;
      description = "Actual managed Cursor hooks used by compatibility checks.";
    };
  };
}
