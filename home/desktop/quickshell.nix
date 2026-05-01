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

  # DMS plugins live in their own GitHub repos; the registry is just
  # an index. Pinning each plugin source so the desktop-widget set is
  # reproducible across machines.
  dms-plugins = {
    cavaVisualizer = pkgs.fetchFromGitHub {
      owner = "ernestowgg";
      repo = "cava-visualizer";
      rev = "e4b65a207652bc3204121401fafd5566b8d22c37";
      hash = "sha256-3Cr+PzPkNGWeIrOqucEc/bLh4xndHI/M3k/srBRCdAQ=";
    };
    dankRssWidget = pkgs.fetchFromGitHub {
      owner = "BrendonJL";
      repo = "dms-rss-widget";
      rev = "dcfe5a638ef2143fc18efdd09ef0b80eacbf35f4";
      hash = "sha256-IzqsQYyBjRv9o4cNSQNRfMYBRmirn/LEGCH2c1fhchw=";
    };
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

  # Desired DMS state. The DMS home-manager module would render these
  # as symlinks into /nix/store, which DMS can't write back to (so
  # mode-driven wallpaper swap, widget drag, and any UI mutation
  # silently fail). Instead we render them to writable copies via
  # home.activation below; DMS owns runtime state, and a rebuild
  # only re-seeds the live file when it is missing or still a
  # symlink to /nix/store. To force a reset to Nix-defined state,
  # delete the live file and rebuild.
  desiredSettings = lib.recursiveUpdate (builtins.fromJSON (builtins.readFile ./dms-settings.json)) {
    currentThemeName = "dynamic";
    currentThemeCategory = "dynamic";
    registryThemeVariants = {
      peaceAndQuiet = "blue";
    };
    syncModeWithPortal = true;
    terminalsAlwaysDark = true;
    notificationPopupPosition = -1;
    cursorSettings = {
      niri = {
        hideWhenTyping = true;
      };
    };
    fontFamily = "Cantarell";
    fontWeight = 600;
    fontScale = 1.25;
    useFahrenheit = true;
    acLockTimeout = 1200;
    batteryLockTimeout = 1200;
    lockBeforeSuspend = true;
    blurEnabled = true;
    desktopClockEnabled = false;
    systemMonitorEnabled = false;
    # Positions are in DMS logical pixels (post-scale). Workstation
    # DP-1 is 3840x2160 @ scale 1.25 → 3072x1728 logical.
    desktopWidgetInstances = [
      {
        id = "dw_sysmon_primary";
        widgetType = "systemMonitor";
        name = "System Monitor";
        enabled = true;
        config = { };
        positions = {
          "DP-1" = {
            x = 16;
            y = 52;
            width = 660;
            height = 1380;
          };
        };
      }
      {
        id = "dw_cava_primary";
        widgetType = "cavaVisualizer";
        name = "Cava Visualizer";
        enabled = true;
        config = { };
        positions = {
          "DP-1" = {
            x = 0;
            y = 1640;
            width = 3072;
            height = 240;
          };
        };
      }
      {
        id = "dw_rss_primary";
        widgetType = "dankRssWidget";
        name = "Dank RSS Widget";
        enabled = true;
        config = {
          # Initial feed list — DankRssWidget reads this via
          # loadValue("feeds", []). Mutable at runtime now that
          # settings.json is a real file (not a /nix/store symlink).
          feeds = [
            {
              name = "Simon Willison";
              url = "https://simonwillison.net/atom/everything/";
            }
            {
              name = "Hacker News";
              url = "https://hnrss.org/frontpage";
            }
            {
              name = "Ars Technica";
              url = "https://feeds.arstechnica.com/arstechnica/index";
            }
            {
              name = "Google Research";
              url = "https://blog.research.google/feeds/posts/default";
            }
            {
              name = "arXiv cs.AI";
              url = "https://arxiv.org/rss/cs.AI";
            }
            {
              name = "MIT Tech Review";
              url = "https://www.technologyreview.com/feed/";
            }
            {
              name = "LWN.net";
              url = "https://lwn.net/headlines/rss";
            }
            {
              name = "Phoronix";
              url = "https://www.phoronix.com/rss.php";
            }
            {
              name = "It's FOSS";
              url = "https://itsfoss.com/feed/";
            }
            {
              name = "OMG Ubuntu";
              url = "https://www.omgubuntu.co.uk/feed";
            }
            {
              name = "DistroWatch";
              url = "https://distrowatch.com/news/dw.xml";
            }
            {
              name = "The Go Blog";
              url = "https://go.dev/blog/feed.atom";
            }
            {
              name = "Dave Cheney";
              url = "https://dave.cheney.net/feed";
            }
            {
              name = "Eli Bendersky";
              url = "https://eli.thegreenplace.net/feeds/all.atom.xml";
            }
            {
              name = "r/golang";
              url = "https://www.reddit.com/r/golang/.rss";
            }
            {
              name = "Ardan Labs";
              url = "https://www.ardanlabs.com/blog/index.xml";
            }
            {
              name = "WSJ Markets";
              url = "https://feeds.a.dj.com/rss/RSSMarketsMain.xml";
            }
            {
              name = "Calculated Risk";
              url = "https://www.calculatedriskblog.com/feeds/posts/default";
            }
            {
              name = "A Wealth of Common Sense";
              url = "https://awealthofcommonsense.com/feed/";
            }
            {
              name = "Of Dollars And Data";
              url = "https://ofdollarsanddata.com/feed/";
            }
            {
              name = "Marginal Revolution";
              url = "https://marginalrevolution.com/feed";
            }
            {
              name = "Reuters Business";
              url = "https://www.reutersagency.com/feed/?best-topics=business-finance&post_type=best";
            }
          ];
        };
        positions = {
          "DP-1" = {
            x = 2396;
            y = 52;
            width = 660;
            height = 1380;
          };
        };
      }
    ];
  };

  desiredSession = lib.recursiveUpdate (builtins.fromJSON (builtins.readFile ./dms-session.json)) {
    perModeWallpaper = true;
    wallpaperPath = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
    wallpaperPathDark = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
    wallpaperPathLight = "${wallpapers}/share/wallpapers/blue-jays.png";
  };

  settingsSource = pkgs.writeText "dms-settings.json" (builtins.toJSON desiredSettings);
  sessionSource = pkgs.writeText "dms-session.json" (builtins.toJSON desiredSession);
in
{
  imports = [ inputs.dms.homeModules.dank-material-shell ];

  programs.dank-material-shell = {
    enable = useDms;
    # Don't generate the systemd user unit. The unit lands in app.slice,
    # outside the graphical logind session — polkit refuses to register
    # DMS's PolkitAuthModal from there. Instead, niri spawns DMS via
    # spawn-at-startup so it inherits niri's logind session (class=user),
    # which lets DMS own the polkit auth-agent slot.
    systemd = {
      enable = false;
      target = "graphical-session.target";
    };

    # `dgop` is not in nixpkgs-25.11 yet — pull from unstable.
    dgop.package = pkgs-unstable.dgop;

    # No VPN widget is configured, so skip pulling glib/networkmanager
    # dependencies just for it.
    enableVPN = false;

    # settings/session intentionally omitted here. The DMS home module
    # would render them as /nix/store symlinks, which DMS can't write
    # to (so mode-driven wallpaper swap, widget drag, runtime UI
    # mutation all silently fail). The desired content is rendered to
    # writable copies via home.activation.dms-bootstrap-state below.
    # See `desiredSettings` and `desiredSession` in the let block.
  };

  # Optional DMS feature backends — only installed when DMS is active.
  # cava: required by the cavaVisualizer desktop widget.
  home.packages = lib.optionals useDms [
    danksearch
    pkgs.cava
  ];

  # Mount registry theme directories into DMS's expected location.
  # DMS reads ~/.config/DankMaterialShell/themes/<dir>/theme.json on
  # startup. Each entry below symlinks the whole theme dir from the
  # pinned registry checkout. Plugins are mounted the same way under
  # plugins/<id>/, sourced from each plugin's upstream repo.
  xdg.configFile = lib.mkIf useDms (
    (lib.mapAttrs' (dir: _id: {
      name = "DankMaterialShell/themes/${dir}";
      value.source = "${dms-registry}/themes/${dir}";
    }) themes)
    // (lib.mapAttrs' (id: src: {
      name = "DankMaterialShell/plugins/${id}";
      value.source = src;
    }) dms-plugins)
  );

  # Seed DMS settings/session as writable files (not /nix/store
  # symlinks), so the runtime can mutate them — wallpaper swap on
  # mode toggle, widget drag, etc. Only installs when the live file
  # is missing or still a stale symlink. To force a reset to the
  # Nix-defined state, delete the live file and rebuild.
  home.activation.dms-bootstrap-state = lib.mkIf useDms (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      install_writable() {
        local target="$1"
        local source="$2"
        run mkdir -p "$(dirname "$target")"
        if [ -L "$target" ] || [ ! -e "$target" ]; then
          run rm -f "$target"
          run install -m 644 "$source" "$target"
        fi
      }
      install_writable "$HOME/.config/DankMaterialShell/settings.json" "${settingsSource}"
      install_writable "$HOME/.local/state/DankMaterialShell/session.json" "${sessionSource}"
    ''
  );
}
