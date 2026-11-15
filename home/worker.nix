{
  config,
  lib,
  pkgs,
  owner,
  ...
}:
{
  imports = [
    ./cli
    ./worker-desktop.nix
    ./services/pi-models.nix
    ./services/litellm.nix
    ./services/shared-vault.nix
  ];
  home = {
    username = owner.name;
    homeDirectory = "/home/${owner.name}";
    stateVersion = "24.11";
    sessionPath = [ "$HOME/.local/bin" ];
    sessionVariables = {
      SCCACHE_DIR = "${config.home.homeDirectory}/.cache/sccache";
      SCCACHE_CACHE_SIZE = "40G";
    };
    packages = [
      (pkgs.callPackage ../pkgs/herdr-core.nix { })
      pkgs.sccache
    ];
  };
  programs.home-manager.enable = true;
  _module.args.wallpapers = lib.mkDefault null;
}
