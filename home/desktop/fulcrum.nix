{
  config,
  lib,
  pkgs,
  hostName,
  ...
}:
let
  # The backend already runs from this checkout. Fetch only on its verified
  # host, so other machines do not need this local repository or its credentials.
  # Keep the package pinned independently of the checkout's working changes.
  source = builtins.fetchGit {
    url = "file://${config.home.homeDirectory}/projects/work/fulcrum";
    rev = "459a86487701d1b698011a203f5c4774fbe1130e";
    allRefs = true;
  };
  cfg = config.my.fulcrum.desktop;
in
{
  options.my.fulcrum.desktop.package = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    description = "Revision-pinned local Fulcrum desktop; null disables installation.";
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
