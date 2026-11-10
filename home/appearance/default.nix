{
  config,
  lib,
  pkgs,
  unstable-pkgs,
  appearance,
  useNoctalia ? false,
  ...
}:
let
  enabled = appearance.isGruvbox && useNoctalia;
  python = pkgs.python3.withPackages (ps: [
    ps.tomlkit
    ps.json5
  ]);
  source = builtins.path {
    name = "desktop-appearance";
    path = ./.;
  };
  toolkit = import ./toolkit.nix { inherit lib appearance; };
  wallpapers = pkgs.callPackage ../../pkgs/gruvbox-wallpapers.nix { };
  landscapeWallpaper = "${../../assets/wallpapers/chiryu-horse-fair.jpg}";
  paletteFiles = lib.genAttrs [ "dark" "light" ] (mode: {
    gtk3 = pkgs.writeText "gruvbox-gtk3-${mode}.css" toolkit.${mode}.gtk3;
    gtk4 = pkgs.writeText "gruvbox-gtk4-${mode}.css" toolkit.${mode}.gtk4;
    qt = pkgs.writeText "gruvbox-qt-${mode}.conf" toolkit.${mode}.qt;
    gtk2 = pkgs.writeText "gruvbox-gtk2-${mode}.rc" ''
      gtk-theme-name="Gruvbox-${if mode == "dark" then "Dark" else "Light"}"
    '';
  });
  json = values: {
    format = "json";
    set = values;
  };
  ini = values: {
    format = "ini";
    set = values;
  };
  qtSettings = version: {
    Appearance = {
      color_scheme_path = "${config.xdg.configHome}/${version}/colors/gruvbox.conf";
      custom_palette = "true";
      style = "Fusion";
      standard_dialogs = "default";
    };
    Fonts = {
      general = ''"Noto Sans,10,-1,5,50,0,0,0,0,0"'';
      fixed = ''"CaskaydiaMono Nerd Font,11,-1,5,50,0,0,0,0,0"'';
    };
  };
  baseManifest = pkgs.writeText "gruvbox-app-settings.json" (
    builtins.toJSON {
      "@CONFIG@/Cursor/User/settings.json" = json {
        "window.autoDetectColorScheme" = true;
        "workbench.colorTheme" = "Gruvbox Dark Medium";
        "workbench.preferredDarkColorTheme" = "Gruvbox Dark Medium";
        "workbench.preferredLightColorTheme" = "Gruvbox Light Medium";
      };
      "@CONFIG@/opencode/cli.json" = json {
        theme = {
          name = "system";
          mode = "system";
        };
      };
      "${config.home.homeDirectory}/.pi/agent/settings.json" = json {
        theme = "gruvbox-light/gruvbox-dark";
      };
      "@CONFIG@/herdr-app/settings.json" =
        (json {
          theme = {
            dark = "gruvbox-dark";
            light = "gruvbox-light";
          };
        })
        // {
          remove = [
            "appearance"
            "colors"
          ];
        };
      "@CONFIG@/qt5ct/qt5ct.conf" = ini (qtSettings "qt5ct");
      "@CONFIG@/qt6ct/qt6ct.conf" = ini (qtSettings "qt6ct");
    }
  );
  modeManifests = lib.genAttrs [ "dark" "light" ] (
    mode:
    pkgs.writeText "gruvbox-${mode}-settings.json" (
      builtins.toJSON {
        "@CONFIG@/kdeglobals" = ini toolkit.${mode}.kde;
        "@CONFIG@/strata/settings.toml" = {
          format = "toml";
          set = {
            mode = "theme";
            theme = "gruvbox-${mode}";
          };
        };
      }
    )
  );
  wallpaperModes = lib.genAttrs [ "dark" "light" ] (mode: {
    default = landscapeWallpaper;
    monitors = {
      Virtual-1 = landscapeWallpaper;
      Virtual-2 = "${wallpapers}/portrait-${mode}.jpg";
      Virtual-3 = "${wallpapers}/portrait-${mode}.jpg";
    };
  });
  settings = pkgs.writeText "gruvbox-policy.json" (
    builtins.toJSON {
      inherit
        paletteFiles
        baseManifest
        modeManifests
        wallpaperModes
        ;
      noctalia = lib.getExe unstable-pkgs.noctalia;
      gsettings = "${pkgs.glib}/bin/gsettings";
      gsettingsSchemaDir = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";
      config = config.xdg.configHome;
      state = config.xdg.stateHome;
    }
  );
  apply = pkgs.writeShellApplication {
    name = "desktop-colors";
    text = ''
      exec ${lib.getExe python} ${source}/sync.py ${settings} "$@"
    '';
  };
  herdrTheme =
    mode:
    let
      c = appearance.${mode};
    in
    {
      background = c.base;
      foreground = c.text;
      selection = c.surface1;
      cursor = c.text;
      ansi = [
        c.base
        c.red
        c.green
        c.yellow
        c.blue
        c.mauve
        c.teal
        c.subtext1
        c.overlay0
        c.red
        c.green
        c.yellow
        c.blue
        c.mauve
        c.teal
        c.text
      ];
      colors = {
        canvas = c.base;
        chrome = c.mantle;
        surface = c.surface0;
        border = c.surface1;
        accent = c.green;
        inherit (c) text;
        muted = c.overlay0;
      };
    };
  strataTheme =
    mode:
    let
      c = appearance.${mode};
    in
    {
      name = "Gruvbox ${mode}";
      background = c.base;
      surface = c.surface0;
      inherit (c) text;
      accent = c.green;
      danger = c.red;
      muted = c.surface1;
      highlight = c.surface1;
      border = c.surface2;
      dim_text = c.overlay0;
      syntax_keyword = c.mauve;
      syntax_string = c.green;
      syntax_constant = c.peach;
      syntax_type = c.yellow;
      syntax_preprocessor = c.teal;
    };
in
{
  config = lib.mkIf enabled {
    home.packages = [ apply ];
    home.file.".cursor/extensions/jdinhlife.gruvbox".source =
      "${pkgs.vscode-extensions.jdinhlife.gruvbox}/share/vscode/extensions/jdinhlife.gruvbox";
    xdg.configFile = lib.mkMerge (
      map
        (mode: {
          "herdr-app/themes/gruvbox-${mode}.json".text = builtins.toJSON (herdrTheme mode);
          "strata/themes/gruvbox-${mode}.toml".source =
            (pkgs.formats.toml { }).generate "strata-gruvbox-${mode}.toml"
              (strataTheme mode);
        })
        [
          "dark"
          "light"
        ]
    );
    home.activation = {
      retireGruvboxTrial = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
        run ${lib.getExe python} ${./configure.py} prepare --config ${lib.escapeShellArg config.xdg.configHome} --state ${lib.escapeShellArg config.xdg.stateHome}
      '';
      gruvboxAppearance = lib.hm.dag.entryAfter [ "linkGeneration" "dconfSettings" ] ''
        run ${lib.getExe apply} activate
      '';
    };
    services.darkman = {
      darkModeScripts.gruvbox = "${lib.getExe apply} dark";
      lightModeScripts.gruvbox = "${lib.getExe apply} light";
    };
    systemd.user.services.noctalia.Service = {
      # Prepare the persisted theme and wallpapers before the shell opens them.
      # No post-start IPC: Noctalia's simple service can precede socket readiness.
      ExecStartPre = [ "${lib.getExe apply} prepare" ];
    };
  };
}
