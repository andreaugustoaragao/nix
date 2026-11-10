{
  config,
  lib,
  pkgs,
  unstable-pkgs,
  wallpapers,
  personalOnly,
  useNoctalia ? false,
  lockScreen ? false,
  ...
}:
let
  package = unstable-pkgs.noctalia;
  recorder = pkgs.writeShellApplication {
    name = "noctalia-record-call";
    text = ''
      exec record-call "$@"
    '';
  };
in
{
  imports = lib.optionals useNoctalia [ (package.src + "/nix/home-module.nix") ];

  config = lib.optionalAttrs useNoctalia {
    programs.noctalia = {
      enable = true;
      inherit package;
      systemd.enable = true;
      settings = import ./noctalia-settings.nix {
        inherit
          lib
          pkgs
          wallpapers
          personalOnly
          lockScreen
          ;
        inherit (config.my) displays;
      };
    };

    home.packages = [ recorder ];

    systemd.user.services.noctalia = {
      Unit = {
        ConditionEnvironment = "WAYLAND_DISPLAY";
        Conflicts = [
          "dms.service"
          "wl-mako.service"
          "wl-waybar.service"
          "wl-swayosd.service"
          "wl-hyprpaper.service"
          "wl-eww.service"
        ];
        After = [ "dms.service" ];
      };
      Service = {
        RestartSec = 2;
        Environment = [
          "PATH=${
            lib.makeBinPath [
              package
              recorder
              pkgs.wireplumber
              pkgs.glib
              pkgs.darkman
            ]
          }:%h/.nix-profile/bin:/etc/profiles/per-user/%u/bin:/run/wrappers/bin:/run/current-system/sw/bin"
        ];
      };
    };
  };
}
