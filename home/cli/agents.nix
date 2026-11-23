{
  lib,
  pkgs,
  hostName,
  isBuildWorker ? false,
  isCloudAgent ? false,
  ...
}:
{
  imports = [
    ./agent-binaries.nix
    ./agent-hub.nix
    ./codex.nix
    ./pi.nix
    ./cursor.nix
    ./shared-vault.nix
    ./vault-v2-clients.nix
    ./herdr.nix
    ./herdr-preview.nix
    ./agent-terminals.nix
    ./agent-projects.nix
    ./herdr-helpers.nix
    ./pstack.nix
    ./portable-skills.nix
    ./grill-me.nix
    ./graphify.nix
  ];
  config.my.vaultV2Clients.configureScript = lib.mkDefault ./shared-vault-configure.py;
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
          || isCloudAgent
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
