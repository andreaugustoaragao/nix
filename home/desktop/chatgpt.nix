{ pkgs, ... }:

{
  home.packages = [ (pkgs.callPackage ../../pkgs/chatgpt-desktop.nix { }) ];

  # Return browser sign-in callbacks to the desktop app.
  xdg.mimeApps.defaultApplications."x-scheme-handler/codex" = "chatgpt.desktop";
}
