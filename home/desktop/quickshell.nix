{
  pkgs,
  lib,
  inputs,
  wallpapers,
  dp1Wallpapers,
  useDms ? false,
  isVm ? false,
  lockScreen ? false,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # DMS currently ignores `useFahrenheit` for CPU temperature widgets and
  # process popouts, so patch the packaged QML to keep hardware temps aligned
  # with the rest of the shell's unit setting.
  dmsPackage = inputs.dms.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      substituteInPlace $out/share/quickshell/dms/Modules/ProcessList/ProcessListPopout.qml \
        --replace-fail 'detail: DgopService.cpuTemperature > 0 ? (DgopService.cpuTemperature.toFixed(0) + "°") : ""' 'detail: DgopService.cpuTemperature > 0 ? ((SettingsData.useFahrenheit ? (DgopService.cpuTemperature * 9 / 5 + 32) : DgopService.cpuTemperature).toFixed(0) + "°" + (SettingsData.useFahrenheit ? "F" : "C")) : ""'

      substituteInPlace $out/share/quickshell/dms/Modules/ProcessList/PerformanceView.qml \
        --replace-fail 'extraInfo: DgopService.cpuTemperature > 0 ? (DgopService.cpuTemperature.toFixed(0) + "°C") : ""' 'extraInfo: DgopService.cpuTemperature > 0 ? ((SettingsData.useFahrenheit ? (DgopService.cpuTemperature * 9 / 5 + 32) : DgopService.cpuTemperature).toFixed(0) + "°" + (SettingsData.useFahrenheit ? "F" : "C")) : ""'

      # DMS writes gsettings color-scheme = "default" for light mode,
      # which the freedesktop spec defines as "no preference" — portal
      # clients (ghostty, etc.) treat it as a fallback to their default
      # (usually dark). Patch to write "prefer-light" instead so ghostty's
      # `theme = dark:...,light:...` syntax actually flips.
      substituteInPlace $out/share/quickshell/dms/Services/PortalService.qml \
        --replace-fail 'const targetScheme = isLightMode ? "default" : "prefer-dark";' 'const targetScheme = isLightMode ? "prefer-light" : "prefer-dark";'

      # DMS bar clock renders children in source order: time, dot, date.
      # Flip the Row to RightToLeft so it visually reads "date • time"
      # without touching the inner time/date StyledTexts (text content
      # within each child still flows LTR).
      substituteInPlace $out/share/quickshell/dms/Modules/DankBar/Widgets/Clock.qml \
        --replace-fail 'spacing: Theme.spacingS' 'spacing: Theme.spacingS; layoutDirection: Qt.RightToLeft'
    '';
  });

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
    # In-tree DankBar pill: toggles `record-call` and reflects state
    # changes made from the CLI by polling its session.env state file.
    recordCall = ./dms-plugins/record-call;
    # Custom bar pill: memory usage in x/y (%) format.
    memoryUsageBar = ./dms-plugins/memory-usage;
    # Custom bar pill: disk usage in x/y (%) format.
    diskUsageBar = ./dms-plugins/disk-usage;
    # Native DMS bar pill + popout: CPU package temps, board fans, GPU, RAM, NVMe.
    thermalMonitor = ./dms-plugins/thermal-monitor;
    # Inline volume slider: drags the default PipeWire sink, wheel-scrolls,
    # icon-click toggles mute. Sits next to the control-center button.
    volumeSlider = ./dms-plugins/volume-slider;
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
    # DMS Catppuccin uses Mocha as the dark base and Latte as the light
    # base; this selects the canonical mauve accent.
    currentThemeName = "cat-mauve";
    currentThemeCategory = "catppuccin";
    registryThemeVariants = {
      peaceAndQuiet = "blue";
    };
    syncModeWithPortal = true;
    # Terminals + nvim are pinned to the Catppuccin palette
    # (Mocha dark / Latte light) — see home/desktop/{ghostty,kitty,
    # alacritty,foot}.nix and home/cli/nvim-lazyvim.nix. Disable DMS's
    # mode-aware matugen renders for these so they don't fight us.
    # waybar + fuzzel still go through matugen for wallpaper-derived
    # chrome (see home/desktop/matugen.nix).
    matugenTemplateGhostty = false;
    matugenTemplateKitty = false;
    matugenTemplateFoot = false;
    matugenTemplateAlacritty = false;
    matugenTemplateNeovim = false;
    notificationPopupPosition = -1;
    cursorSettings = {
      niri = {
        hideWhenTyping = true;
      };
    };
    fontFamily = "Cantarell";
    fontWeight = 600;
    fontScale = 1.25;
    useFahrenheit = false;
    # VMs (and any host with lockScreen = false) skip DMS locking so the
    # hypervisor's lock screen is the only one you need to dismiss.
    acLockTimeout = if lockScreen then 1200 else 0;
    batteryLockTimeout = if lockScreen then 1200 else 0;
    lockBeforeSuspend = lockScreen;
    loginctlLockIntegration = lockScreen;
    fadeToLockEnabled = lockScreen;
    powerMenuActions =
      lib.filter (a: lockScreen || a != "lock")
        (builtins.fromJSON (builtins.readFile ./dms-settings.json)).powerMenuActions;
    blurEnabled = true;
    desktopClockEnabled = false;
    systemMonitorEnabled = false;
    scrollTitleEnabled = false;
    mediaSize = 0;
    # Positions are in DMS logical pixels (post-scale). Widgets live
    # only on DP-2 (portrait, 1440x2560 logical) — DP-1 is reserved
    # for windows. `config.displayPreferences` is what DMS actually
    # consults to decide visibility (see DesktopWidgetLayer.qml);
    # the `positions` map only carries x/y/width/height per display.
    desktopWidgetInstances = [
      {
        id = "dw_cava_primary";
        widgetType = "cavaVisualizer";
        name = "Cava Visualizer";
        enabled = true;
        config = {
          displayPreferences = [ "DP-2" ];
        };
        positions = {
          "DP-2" = {
            x = 16;
            y = 2240;
            width = 1408;
            height = 280;
          };
        };
      }
    ];

    # Per-monitor bars. The default bar (full widget set) is scoped to
    # DP-1; DP-2 (portrait, only 1440 logical wide) gets a slimmed-down
    # version that drops widgets duplicated by the desktop System
    # Monitor (cpu/mem/disk/network) and other desktop-irrelevant ones
    # (battery, idleInhibitor).
    barConfigs =
      let
        baseRaw = builtins.elemAt (builtins.fromJSON (builtins.readFile ./dms-settings.json)).barConfigs 0;
        # VMs have no real temperature sensors, so drop CPU/GPU temp widgets.
        base =
          if isVm then
            baseRaw
            // {
              rightWidgets = builtins.filter (
                w:
                !(builtins.elem w.id [
                  "thermalMonitor"
                  "gpuTemp"
                ])
              ) baseRaw.rightWidgets;
            }
          else
            baseRaw;
      in
      [
        (
          base
          // {
            screenPreferences = [ "DP-1" ];
          }
        )
        (
          base
          // {
            id = "dp2";
            name = "Portrait Bar";
            screenPreferences = [ "DP-2" ];
            showOnLastDisplay = false;
            leftWidgets = [
              "clock"
              "workspaceSwitcher"
            ];
            centerWidgets = [ ];
            rightWidgets = [
              {
                id = "clipboard";
                enabled = true;
              }
              {
                id = "notificationButton";
                enabled = true;
              }
              {
                id = "controlCenterButton";
                enabled = true;
              }
              {
                id = "privacyIndicator";
                enabled = true;
              }
              {
                id = "systemTray";
                enabled = true;
                trayUseInlineExpansion = false;
              }
            ];
            fontScale = 0.85;
            iconScale = 0.9;
          }
        )
      ];
  };

  desiredPluginSettings = {
    recordCall = {
      enabled = true;
    };
    memoryUsageBar = {
      enabled = true;
    };
    diskUsageBar = {
      enabled = true;
      mountPath = "/";
    };
    thermalMonitor = {
      enabled = true;
    };
    volumeSlider = {
      enabled = true;
      # Bar pill width in logical pixels. Bump if the slider feels cramped.
      sliderWidth = 160;
    };
  };

  desiredSession = lib.recursiveUpdate (builtins.fromJSON (builtins.readFile ./dms-session.json)) {
    perModeWallpaper = true;
    perMonitorWallpaper = true;
    # DP-1: 32M2V landscape (3840x2160). DP-2: Dell S2725QS portrait
    # (2160x3840 after niri's transform=270). Per-monitor wallpapers
    # let each display use a print sized for its orientation.
    wallpaperPath = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
    wallpaperPathDark = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
    wallpaperPathLight = "${wallpapers}/share/wallpapers/blue-jays.png";
    # SessionData.getMonitorWallpaper reads from `monitorWallpapers` (the
    # active per-mode copy), not from monitorWallpapersDark/Light directly.
    # That map is only populated by syncWallpaperForCurrentMode(), which
    # runs on mode *change* — not on first load — so a cold boot in dark
    # mode leaves the map empty and DP-2 silently falls back to
    # wallpaperPath. Seed it with the dark mapping so the boot state
    # renders correctly without a mode toggle; the first setLightMode(true)
    # of the day overwrites it from monitorWallpapersLight.
    monitorWallpapers = {
      "DP-1" = dp1Wallpapers.dark;
      "DP-2" = "${wallpapers}/share/wallpapers/atake-sudden-shower.jpg";
    };
    monitorWallpapersDark = {
      "DP-1" = dp1Wallpapers.dark;
      "DP-2" = "${wallpapers}/share/wallpapers/atake-sudden-shower.jpg";
    };
    monitorWallpapersLight = {
      "DP-1" = dp1Wallpapers.light;
      "DP-2" = "${wallpapers}/share/wallpapers/kameido-plum-park.jpg";
    };
    monitorWallpaperFillModes = {
      "DP-1" = "Fill";
      "DP-2" = "Fit";
    };
  };

  settingsSource = pkgs.writeText "dms-settings.json" (builtins.toJSON desiredSettings);
  pluginSettingsSource = pkgs.writeText "dms-plugin-settings.json" (
    builtins.toJSON desiredPluginSettings
  );
  sessionSource = pkgs.writeText "dms-session.json" (builtins.toJSON desiredSession);
in
{
  imports = [ inputs.dms.homeModules.dank-material-shell ];

  programs.dank-material-shell = {
    enable = useDms;
    package = dmsPackage;
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
    # to (so mode-driven wallpaper swap silently fails). Instead they
    # are written to writable copies via home.activation.dms-write-state
    # below, with Nix as the authoritative source on every rebuild.
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
      value = {
        source = src;
        # Plugin assets are authoritative from Nix; replace any stale
        # symlink/dir HM finds at the target. Leftovers happen when the
        # plugin source path changes between generations.
        force = true;
      };
    }) dms-plugins)
  );

  # Render DMS settings/session as writable files (not /nix/store
  # symlinks, which DMS can't write back to and would break runtime
  # mode-driven wallpaper swap). Nix is authoritative: every rebuild
  # overwrites the live file with the Nix-defined content. DMS may
  # mutate the file at runtime (mode toggle writes wallpaperPath,
  # widget drag writes positions), but those mutations are reset on
  # the next rebuild — change config in Nix, not in the DMS UI.
  home.activation.dms-write-state = lib.mkIf useDms (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      install_authoritative() {
        local target="$1"
        local source="$2"
        run mkdir -p "$(dirname "$target")"
        run rm -f "$target"
        run install -m 644 "$source" "$target"
      }
      install_authoritative "$HOME/.config/DankMaterialShell/settings.json" "${settingsSource}"
      install_authoritative "$HOME/.config/DankMaterialShell/plugin_settings.json" "${pluginSettingsSource}"
      install_authoritative "$HOME/.local/state/DankMaterialShell/session.json" "${sessionSource}"
    ''
  );
}
