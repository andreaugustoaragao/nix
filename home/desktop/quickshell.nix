{
  pkgs,
  lib,
  inputs,
  wallpapers,
  useDms ? false,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # `danksearch` is the indexed filesystem search backend DMS's launcher
  # uses. Not in nixpkgs, so we build from upstream against a pinned rev.
  danksearch = pkgs.buildGoModule {
    pname = "danksearch";
    version = "unstable-2026-04-25";
    src = pkgs.fetchFromGitHub {
      owner = "AvengeMedia";
      repo = "danksearch";
      rev = "18591ecaa4b87acb222391f9aedd2fbbef9c087f";
      sha256 = "06gb90cb7xq7sdpfima457l4jbjly7q63pips4mw31wj8nz20b59";
    };
    vendorHash = "sha256-nvAgDX8dS3ZwAGTdPvNK1/XzlY28/QjRSW8cmqhp9io=";
    meta = {
      description = "Indexed filesystem search backend for DankMaterialShell";
      homepage = "https://github.com/AvengeMedia/danksearch";
      mainProgram = "danksearch";
      license = lib.licenses.mit;
    };
  };
in
{
  imports = [ inputs.dms.homeModules.dank-material-shell ];

  programs.dank-material-shell = {
    enable = useDms;
    systemd = {
      enable = useDms;
      target = "graphical-session.target";
    };

    # `dgop` is not in nixpkgs-25.11 yet — pull from unstable.
    dgop.package = pkgs-unstable.dgop;

    # No VPN widget is configured, so skip pulling glib/networkmanager
    # dependencies just for it.
    enableVPN = false;

    # Full DMS state captured into Nix. The two snapshot files were
    # copied verbatim from ~/.config and ~/.local/state on 2026-04-28;
    # any further tweaks happen by editing those JSON files (or by
    # overriding individual keys via lib.recursiveUpdate below).
    settings = lib.mkIf useDms (builtins.fromJSON (builtins.readFile ./dms-settings.json));

    session = lib.mkIf useDms (
      lib.recursiveUpdate
        (builtins.fromJSON (builtins.readFile ./dms-session.json))
        {
          # Per-mode wallpapers from the flake's assets/wallpapers/.
          perModeWallpaper   = true;
          wallpaperPath      = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
          wallpaperPathDark  = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
          wallpaperPathLight = "${wallpapers}/share/wallpapers/fuji-day.jpg";
        }
    );
  };

  # Optional DMS feature backends — only installed when DMS is active.
  home.packages = lib.optionals useDms [ danksearch ];
}
