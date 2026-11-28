{
  lib,
  pkgs,
  wallpapers,
  displays,
  personalOnly,
  lockScreen,
  appearance ? null,
  homeDirectory ? null,
  preview ? false,
  showTemperatures ? false,
  allowEmptyPassword ? false,
}:
let
  barScale = 0.825;
  portraitBarScale = barScale * 1.1;
in
lib.recursiveUpdate
  (lib.recursiveUpdate (builtins.fromTOML (builtins.readFile ./noctalia-personal.toml)) {
    shell = {
      font_family = "Noto Sans";
      # The compositor's existing auth agent owns the graphical logind session.
      polkit_agent = false;
      launch_apps_as_systemd_services = !preview;
      niri_overview_type_to_launch_enabled = true;
      niri_overview_close_on_launch_enabled = true;
      readline_shortcuts = true;
      launcher = {
        layout = "simple";
        categories = false;
        compact = true;
        show_app_origin_indicator = false;
      };
      window_switcher = {
        mru = true;
      };
      screenshot = {
        annotate = true;
        copy_to_clipboard = true;
        save_to_file = true;
        freeze_screen = true;
        show_region_dimensions = true;
        show_region_hint = true;
        close_on_copy = true;
        close_on_save = true;
      }
      // lib.optionalAttrs (homeDirectory != null) {
        directory = "${homeDirectory}/pictures/screenshots";
      };
    }
    // lib.optionalAttrs (homeDirectory != null) {
      avatar_path = "${homeDirectory}/.face";
    };
    theme = {
      builtin = if appearance != null && appearance.isGruvbox then "Gruvbox" else "Catppuccin";
      sync_color_scheme = !preview;
      templates = {
        enable_builtin_templates = false;
        enable_community_templates = false;
      };
    };
    bar.main = {
      font_family = "Noto Sans";
      font_weight = 500;
      thickness = 40;
      radius = 16;
      scale = barScale;
      monitor = {
        portrait.scale = portraitBarScale;
        third.scale = portraitBarScale;
      };
      font_scale = 1.0;
      widget_spacing = 5;
      capsule_padding = 4.5;
      # Only the centered console paints a background; the rest passes clicks through.
      background_opacity = 0.0;
      border_width = 0.0;
      margin_edge = 10;
      dead_zone.click_through = true;
      capsule = false;
      capsule_thickness = 1.0;
      capsule_fill = "surface_container";
      capsule_opacity = 1.0;
    };
    osd = {
      position = "bottom_center";
      position_vertical = "bottom_center";
    };
    dock.reserve_space = false;
    wallpaper = {
      directory = "${wallpapers}/share/wallpapers";
      default.path = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
      fill_mode = "crop";
      transition = [ ];
      automation.enabled = false;
    };
    lockscreen = {
      enabled = lockScreen;
      lock_before_suspend = lockScreen;
      allow_empty_password = allowEmptyPassword;
    };
    idle.behavior.lock = {
      enabled = lockScreen;
      timeout = 1200;
      action = "lock";
    };
    hooks = lib.optionalAttrs (!preview) {
      theme_mode_changed = "${lib.getExe pkgs.darkman} set \"$NOCTALIA_THEME_MODE\"";
    };
  })
  (
    import ./noctalia-toolbar.nix {
      inherit
        lib
        displays
        personalOnly
        showTemperatures
        ;
    }
  )
