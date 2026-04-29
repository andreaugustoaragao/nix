{
  config,
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

  # DMS plugin/theme registry — pinned to a specific commit. Themes and
  # plugin specs are mirrored into ~/.config/DankMaterialShell/themes/ so
  # DMS picks them up on startup.
  dms-registry = pkgs.fetchFromGitHub {
    owner = "AvengeMedia";
    repo = "dms-plugin-registry";
    rev = "ffdc299f9da9f5c30599c9c5ea01849d4627d48a";
    sha256 = "1wyw08q7r4d1c9ccm9gnr9j87yj1z8vz6nrw6yf827pw0vvgg7mv";
  };

  # The five themes that should ship with this machine. Each maps the
  # registry directory name → DMS theme id (from theme.json's `id` field).
  themes = {
    "gruvbox-material" = "gruvboxMaterial";
    "kanagawa-wl" = "kanagawaWl";
    "nord" = "nord";
    "peace-and-quiet" = "peaceAndQuiet";
    "rose-pine" = "rosePine";
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
    settings = lib.mkIf useDms (
      lib.recursiveUpdate
        (builtins.fromJSON (builtins.readFile ./dms-settings.json))
        {
          # Default to dynamic (wallpaper-derived) theming so DMS itself
          # follows whatever palette matugen extracts from the active
          # wallpaper. The five registry themes mounted below stay
          # available in the Browse picker — flip currentThemeName to
          # "custom" + set customThemeFile/category=registry to use them.
          currentThemeName = "dynamic";
          currentThemeCategory = "dynamic";
          # Pre-select Peace & Quiet's Blue variant so it's already
          # configured if you switch to that theme via the picker.
          registryThemeVariants = {
            peaceAndQuiet = "blue";
          };
          # Application toggles in DMS Theme tab.
          syncModeWithPortal = true;   # XDG portal color-scheme sync
          terminalsAlwaysDark = true;  # force terminals to dark palette

          # Notifications appear at the top-center of the screen
          # (-1 is DMS's special sentinel for top-center; positive
          # values map to SettingsData.Position.{Top,Bottom,Left,Right,...}).
          notificationPopupPosition = -1;

          # Hide the cursor while typing in niri.
          cursorSettings = {
            niri = {
              hideWhenTyping = true;
            };
          };

          # DMS uses one global font for all UI (bar, popups, control
          # center), so this applies to the status bar too.
          # Weight 600 = Demi/Semi Bold.
          fontFamily = "Cantarell";
          fontWeight = 600;

          # Weather in Fahrenheit (default is Celsius).
          useFahrenheit = true;
        }
    );

    session = lib.mkIf useDms (
      lib.recursiveUpdate
        (builtins.fromJSON (builtins.readFile ./dms-session.json))
        {
          # Per-mode wallpapers from the flake's assets/wallpapers/.
          perModeWallpaper   = true;
          wallpaperPath      = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
          wallpaperPathDark  = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
          wallpaperPathLight = "${wallpapers}/share/wallpapers/blue-jays.png";
        }
    );
  };

  # Optional DMS feature backends — only installed when DMS is active.
  home.packages = lib.optionals useDms [ danksearch ];

  # Mount registry theme directories into DMS's expected location.
  # DMS reads ~/.config/DankMaterialShell/themes/<dir>/theme.json on
  # startup. Each entry below symlinks the whole theme dir from the
  # pinned registry checkout.
  xdg.configFile = lib.mkIf useDms (
    lib.mapAttrs' (dir: _id: {
      name = "DankMaterialShell/themes/${dir}";
      value.source = "${dms-registry}/themes/${dir}";
    }) themes
  );
}
