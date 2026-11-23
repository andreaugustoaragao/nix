{
  lib,
  pkgs,
  isServer ? false,
  isCloudAgent ? false,
  ...
}:
{
  imports = [
    ./agent-binaries.nix
    ./codex.nix
    ./pi.nix
    ./cursor.nix
    ./vault-v2-clients.nix
    ./herdr.nix
    ./herdr-preview.nix
    ./agent-terminals.nix
    ./agent-projects.nix
    ./herdr-helpers.nix
    ./pstack.nix
    ./portable-skills.nix
    ./pocock.nix
    ./graphify.nix
  ];
  config.my.vaultV2Clients.configureScript = lib.mkDefault ./shared-vault-configure.py;
  options.my.agentHarness = {
    omp.enable = lib.mkOption {
      type = lib.types.bool;
      default = !isServer || isCloudAgent;
      description = "Install and configure OMP (Oh My Pi) and its Herdr review template.";
    };
    pstackPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Packaged pstack bundle for Cursor CLI --plugin-dir loading.";
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
