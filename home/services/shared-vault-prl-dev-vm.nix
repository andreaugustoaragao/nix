{ config, pkgs, ... }:
let
  pin = builtins.fromJSON (builtins.readFile ./shared-vault-prl-dev-vm-release.json);
in
{
  my.sharedVault = {
    enable = true;
    vaultId = "work-notes";
    runtimeDirectory = "/run/user/1000/shared-vault";
    release = pkgs.callPackage ../../pkgs/shared-vault-release.nix pin;
    releaseId = pin.sourceRevision;
    service = {
      enable = true;
      notesDir = "${config.home.homeDirectory}/projects/work/notes";
      stateDir = "${config.xdg.dataHome}/shared-vault/work-notes";
      recordingsDirectory = "${config.home.homeDirectory}/recordings/calls";
      recordingIntake = {
        agentName = "exec-assistant";
        recordCall = "${config.home.profileDirectory}/bin/record-call";
      };
      vector = {
        url = "http://127.0.0.1:8000";
        namespace = "fulcrum_vault";
      };
      environment = {
        FULCRUM_OCR_EXEC = "${pkgs.tesseract}/bin/tesseract";
        TESSDATA_PREFIX = "${pkgs.tesseract}/share/tessdata";
        FULCRUM_OFFICE_EXEC = "${pkgs.libreoffice}/lib/libreoffice/program/soffice";
        FULCRUM_EMBEDDING_CACHE_DIR = "${config.xdg.cacheHome}/fulcrum/embeddings";
      };
      automation = {
        enable = true;
        executable = "${config.home.homeDirectory}/.local/bin/codex";
        activation = "paused";
        recordingAdmission = "paused";
      };
      cleanup.enable = true;
    };
  };
}
