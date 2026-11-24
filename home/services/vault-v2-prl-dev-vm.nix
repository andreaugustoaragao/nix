{
  config,
  inputs,
  pkgs,
  ...
}:
let
  vaultV2 = pkgs.callPackage ../../pkgs/vault-v2.nix {
    src = inputs.fulcrum-src;
  };
  workIntake = pkgs.callPackage ../../pkgs/fulcrum-work-intake.nix {
    src = inputs.fulcrum-src;
  };
  fulcrumNodeModules = pkgs.callPackage ../../pkgs/fulcrum-node-modules.nix {
    src = inputs.fulcrum-src;
  };
  fulcrumV2WebNodeModules = pkgs.callPackage ../../pkgs/fulcrum-v2-web-node-modules.nix {
    src = inputs.fulcrum-src;
  };
  fulcrumApp = pkgs.callPackage ../../pkgs/fulcrum-app.nix {
    src = inputs.fulcrum-src;
    sourceRevision = inputs.fulcrum-src.rev;
    inherit fulcrumNodeModules fulcrumV2WebNodeModules;
  };
in
{
  my.vaultV2 = {
    enable = true;
    package = vaultV2;
    workIntakePackage = workIntake;
    fulcrumRelease = fulcrumApp;
    vaultId = "work-notes";
    notesDir = "${config.home.homeDirectory}/projects/work/notes";
    stateRoot = "${config.xdg.dataHome}/fulcrum-v2";
    runtimeDir = "/run/user/1000";
    codexExecutable = "${config.home.homeDirectory}/.local/bin/codex";
    piExecutable = "${config.home.homeDirectory}/.local/bin/pi";
    companionSkillSource = "${fulcrumApp}/share/vault-services/config/user-skills/skills/vault-companion";
  };
  my.vaultV2Clients = {
    enable = true;
    package = vaultV2;
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
