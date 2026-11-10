{
  lib,
  pkgs,
  wallpapers,
  displays,
  personalOnly,
  lockScreen,
  preview ? false,
}:
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
      sync_color_scheme = !preview;
      templates = {
        enable_builtin_templates = false;
        enable_community_templates = false;
      };
    };
    bar.main = {
      font_family = "Cantarell";
      font_weight = 600;
      thickness = 32;
      radius = 16;
      scale = 0.825;
      font_scale = 1.0 / 1.1;
      widget_spacing = 5;
      capsule_padding = 4.5;
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
