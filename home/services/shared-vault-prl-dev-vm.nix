{
  config,
  lib,
  pkgs,
  unstable-pkgs,
  ...
}:
let
  pin = builtins.fromJSON (builtins.readFile ./shared-vault-prl-dev-vm-release.json);
  chromium = pkgs.writeShellScript "fulcrum-chromium" ''
    exec ${pkgs.coreutils}/bin/env -u LD_LIBRARY_PATH ${unstable-pkgs.chromium}/bin/chromium "$@"
  '';
in
{
  systemd.user.services.shared-vault = lib.mkIf config.my.sharedVault.service.enable {
    Service = {
      RuntimeDirectory = "shared-vault";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
    };
  };

  my.sharedVault = {
    enable = true;
    vaultId = "work-notes";
    runtimeDirectory = "/run/user/1000/shared-vault";
    release = pkgs.callPackage ../../pkgs/shared-vault-release.nix pin;
    releaseId = pin.sourceRevision;
    service = {
      # Keep disabled until the Rust migration and installed verification pass.
      enable = false;
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
        FULCRUM_NODE_PATH = "${pkgs.nodejs_26}/bin/node";
        FULCRUM_NOTES_DIR = "${config.home.homeDirectory}/projects/work/notes";
        FULCRUM_CHROMIUM_PATH = "${chromium}";
        NIX_LD = "/run/current-system/sw/share/nix-ld/lib/ld.so";
        LOG_LEVEL = "info";
      };
      automation = {
        enable = true;
        executable = "${config.home.homeDirectory}/.local/bin/codex";
        activation = "enabled";
        recordingAdmission = "enabled";
      };
      cleanup.enable = true;
    };
  };
}
