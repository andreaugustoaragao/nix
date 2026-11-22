{
  config,
  pkgs,
  ...
}:
let
  # Single certified immutable release pin produced by home/cli/shared-vault-release.py --pin-output
  # from one validated dev:certify v2 receipt. Supplies Fulcrum (share/vault-services + bin/bun)
  # and all 3 certified native binaries (shared-vault, vault-extract, ai-task-scheduler) together.
  pin = builtins.fromJSON (builtins.readFile ./vault-v2-prl-dev-vm-release.json);
  release = pkgs.callPackage ../../pkgs/shared-vault-release.nix pin;
in
{
  # Retire legacy v1 Bun/Chroma shared-vault service & client hooks on prl-dev-vm.
  my.sharedVault = {
    enable = false;
    service.enable = false;
  };

  my.vaultV2 = {
    enable = true;
    package = release;
    fulcrumRelease = release;
    vaultId = "work-notes";
    notesDir = "${config.home.homeDirectory}/projects/work/notes";
    stateRoot = "${config.xdg.dataHome}/fulcrum-v2";
    runtimeDir = "/run/user/1000";
    codexExecutable = "${config.home.homeDirectory}/.local/bin/codex";
    piExecutable = "${config.home.homeDirectory}/.local/bin/pi";
    companionSkillSource = "${release}/share/vault-services/config/user-skills/skills/vault-companion";
  };

  my.vaultV2Clients = {
    enable = true;
    package = release;
    vaultSocket = "/run/user/1000/shared-vault-v2/api.sock";
    schedulerSocket = "/run/user/1000/ai-task-scheduler/api.sock";
    clients = [
      "codex"
      "cursor"
      "pi"
      "omp"
    ];
  };
}
