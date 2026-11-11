{
  lib,
  pkgs,
  wallpapers,
  displays,
  personalOnly,
  lockScreen,
  appearance ? null,
  preview ? false,
}:
let
  barScale = 0.825;
  portraitBarScale = barScale * 1.1;
in
lib.recursiveUpdate (lib.recursiveUpdate
  (builtins.fromTOML (builtins.readFile ./noctalia-personal.toml))
  {
    shell = {
      font_family = "Cantarell";
      # The compositor's existing auth agent owns the graphical logind session.
      polkit_agent = false;
      launch_apps_as_systemd_services = !preview;
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
      thickness = 32;
      radius = 16;
      scale = barScale;
      monitor = {
        portrait.scale = portraitBarScale;
        third.scale = portraitBarScale;
      };
      font_scale = 1.0;
      widget_spacing = 5;
      capsule_padding = 4.5;
      # Clear the full-width plane. Each widget keeps its own theme pill,
      # and the top margin separates that row from the screen edge.
      background_opacity = 0.0;
      border_width = 0.0;
      margin_edge = 10;
      capsule = true;
      capsule_fill = "surface_container";
      capsule_opacity = 1.0;
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
    };
    idle.behavior.lock = {
      enabled = lockScreen;
      timeout = 1200;
      action = "lock";
    };
    hooks = lib.optionalAttrs (!preview) {
      theme_mode_changed = "${lib.getExe pkgs.darkman} set \"$NOCTALIA_THEME_MODE\"";
    };
  }
) (import ./noctalia-toolbar.nix { inherit lib displays personalOnly; })
