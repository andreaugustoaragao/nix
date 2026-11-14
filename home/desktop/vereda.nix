{
  config,
  lib,
  pkgs,
  unstable-pkgs,
  hostName,
  ...
}:
let
  cfg = config.programs.vereda;
  portalBackends = pkgs.buildEnv {
    name = "vereda-portal-backends";
    paths = config.xdg.portal.extraPortals;
    pathsToLink = [ "/share/xdg-desktop-portal/portals" ];
  };
in
{
  options.programs.vereda = {
    enable = lib.mkEnableOption "Vereda as the desktop file manager";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./vereda-package.nix { zig = unstable-pkgs.zig_0_17; };
      description = "Vereda native Linux file manager.";
    };
  };
  config = lib.mkMerge [
    { programs.vereda.enable = lib.mkDefault (hostName == "prl-dev-vm"); }
    (lib.mkIf cfg.enable {
      home.packages = [ cfg.package ];
      xdg = {
        portal = {
          extraPortals = [ cfg.package ];
          config.niri = {
            default = [
              "gnome"
              "gtk"
            ];
            "org.freedesktop.impl.portal.FileChooser" = [ "vereda" ];
            "org.freedesktop.impl.portal.ScreenCast" = [ "gnome" ];
            "org.freedesktop.impl.portal.RemoteDesktop" = [ "gnome" ];
            "org.freedesktop.impl.portal.Screenshot" = [ "gnome" ];
          };

        };
        configFile = {
          "systemd/user/xdg-desktop-portal-vereda.service".source =
            "${cfg.package}/share/systemd/user/xdg-desktop-portal-vereda.service";
          "systemd/user/xdg-desktop-portal.service.d/20-vereda.conf".text = ''
            [Service]
            Environment=NIX_XDG_DESKTOP_PORTAL_DIR=${portalBackends}/share/xdg-desktop-portal/portals
          '';
        };
        dataFile."dbus-1/services/org.freedesktop.impl.portal.desktop.vereda.service".source =
          "${cfg.package}/share/dbus-1/services/org.freedesktop.impl.portal.desktop.vereda.service";
        dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text = ''
          [D-BUS Service]
          Name=org.freedesktop.FileManager1
          Exec=${lib.getExe cfg.package} --service
        '';
      };
    })
  ];
}
