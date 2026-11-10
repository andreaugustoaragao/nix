{
  config,
  lib,
  pkgs,
  hostName,
  ...
}:
let
  cfg = config.programs.yazi-rune;
in
{
  options.programs.yazi-rune = {
    enable = lib.mkEnableOption "Yazi Rune as the desktop file manager";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./yazi-rune-package.nix { };
      description = "Pinned native Rune file-manager package.";
    };
  };
  config = lib.mkMerge [
    { programs.yazi-rune.enable = lib.mkDefault (hostName == "prl-dev-vm"); }
    (lib.mkIf cfg.enable {
      home.packages = [ cfg.package ];
      xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text = ''
        [D-BUS Service]
        Name=org.freedesktop.FileManager1
        Exec=${lib.getExe cfg.package} --service
      '';
    })
  ];
}
