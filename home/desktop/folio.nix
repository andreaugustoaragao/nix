{
  lib,
  pkgs,
  hostName,
  ...
}:
{
  config = lib.mkIf (hostName == "prl-dev-vm" || hostName == "workstation") {
    home.packages = [ (pkgs.callPackage ../../pkgs/folio.nix { }) ];
    xdg.mimeApps.defaultApplications."text/x-markdown" = "local.folio.Reader.desktop";
  };
}
