{
  config,
  lib,
  pkgs,
  hostName,
  ...
}:
let
  shared = config.my.sharedVault or { enable = false; };
  sourceRoot =
    if shared.enable then
      "${config.home.homeDirectory}/projects/work/fulcrum-releases/${shared.releaseId}"
    else
      "${config.home.homeDirectory}/projects/work/fulcrum";
  pin = builtins.fromJSON (builtins.readFile ./fulcrum-source.json);
  # Desktop keeps its independent revision in the bootstrapped Git history.
  source = builtins.fetchGit {
    url = "file://${sourceRoot}";
    rev = pin.revision;
    allRefs = true;
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
