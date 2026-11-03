{ pkgs, ... }:
{
  home.packages = [ (pkgs.callPackage ../../pkgs/kero.nix { }) ];

  xdg.configFile."kero/config".text = ''
    theme = light:meadow,dark:dusk
  '';
}
