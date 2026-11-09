{
  config,
  lib,
  pkgs,
  hostName,
  ...
}:
let
  pin = builtins.fromJSON (builtins.readFile ./fulcrum-source.json);
  source = pkgs.fetchzip {
    name = "fulcrum-desktop-source";
    url = "https://github.com/andrearagao/fulcrum/archive/${pin.revision}.tar.gz";
    inherit (pin) hash;
  };
  cfg = config.my.fulcrum.desktop;
in
{
  options.my.fulcrum.desktop.package = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    description = "Revision-pinned Fulcrum desktop; null disables installation.";
  };
  config = {
    my.fulcrum.desktop.package = lib.mkIf (hostName == "prl-dev-vm") (
      lib.mkDefault (pkgs.callPackage "${source}/desktop/package.nix" { localMode = true; })
    );
    assertions = [
      {
        assertion = cfg.package == null || hostName == "prl-dev-vm";
        message = "Local Fulcrum Desktop is currently verified only for prl-dev-vm.";
      }
    ];
    home.packages = lib.mkIf (cfg.package != null) [ cfg.package ];
  };
}
