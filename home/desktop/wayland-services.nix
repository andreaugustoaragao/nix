{ config, pkgs, lib, inputs, useDms ? false, ... }:

# When DMS owns the desktop, the daemons it replaces (mako/swayosd/hyprpaper/waybar)
# packages stay installed but their systemd units aren't defined at all. This avoids
# the `linked but not enabled` state where systemd can still auto-restart a unit if
# it ever gets nudged (mako in particular fights DMS for org.freedesktop.Notifications).
{
  # Generic Wayland session services (start when a Wayland compositor is running)
  systemd.user.services.wl-mako = lib.mkIf (!useDms) {
    Unit = {
      Description = "Wayland: mako notification daemon";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${pkgs.mako}/bin/mako";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = { WantedBy = [ "graphical-session.target" ]; };
  };

  systemd.user.services.wl-swayosd = lib.mkIf (!useDms) {
    Unit = {
      Description = "Wayland: swayosd server";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${pkgs.swayosd}/bin/swayosd-server";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = { WantedBy = [ "graphical-session.target" ]; };
  };

  systemd.user.services.wl-hyprpaper = lib.mkIf (!useDms) {
    Unit = {
      Description = "Wayland: hyprpaper wallpaper daemon";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${pkgs.hyprpaper}/bin/hyprpaper";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = { WantedBy = [ "graphical-session.target" ]; };
  };

  # systemd.user.services.wl-alacritty-daemon = {
  #   Unit = {
  #     Description = "Wayland: alacritty daemon";
  #     After = [ "graphical-session.target" ];
  #     PartOf = [ "graphical-session.target" ];
  #     ConditionEnvironment = "WAYLAND_DISPLAY";
  #   };
  #   Service = {
  #     ExecStart = "${pkgs.alacritty}/bin/alacritty --daemon";
  #     Restart = "on-failure";
  #     RestartSec = 2;
  #   };
  #   Install = { WantedBy = [ "graphical-session.target" ]; };
  # };

  systemd.user.services.wl-foot-server = {
    Unit = {
      Description = "Wayland: foot terminal server";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${pkgs.foot}/bin/foot --server";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = { WantedBy = [ "graphical-session.target" ]; };
  };

  systemd.user.services.wl-fcitx5 = {
    Unit = {
      Description = "Wayland: fcitx5 input method";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${pkgs.fcitx5}/bin/fcitx5";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [
        "INPUT_METHOD=fcitx"
        "QT_IM_MODULE=fcitx"
        "XMODIFIERS=@im=fcitx"
        "SDL_IM_MODULE=fcitx"
      ];
    };
    Install = { WantedBy = [ "graphical-session.target" ]; };
  };

  systemd.user.services.wl-eww = {
    Unit = {
      Description = "Wayland: eww status bar";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.eww}/bin/eww --config %h/.config/eww/bar --no-daemonize daemon";
      ExecStartPost = "${pkgs.bash}/bin/bash -c 'until ${pkgs.eww}/bin/eww --config %h/.config/eww/bar ping >/dev/null 2>&1; do sleep 0.1; done; ${pkgs.eww}/bin/eww --config %h/.config/eww/bar open bar'";
      ExecStop = "${pkgs.eww}/bin/eww --config %h/.config/eww/bar kill";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [
        "XDG_CONFIG_HOME=%h/.config"
        "PATH=/run/wrappers/bin:/etc/profiles/per-user/aragao/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
      ];
    };
  };

  systemd.user.services.wl-waybar = lib.mkIf (!useDms) {
    Unit = {
      Description = "Wayland: waybar status bar";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${pkgs.bash}/bin/bash -c 'if [[ \"$XDG_CURRENT_DESKTOP\" == *\"niri\"* ]]; then ${pkgs.waybar}/bin/waybar -c ~/.config/waybar/niri-config.json -s ~/.config/waybar/style.css; else ${pkgs.waybar}/bin/waybar -c ~/.config/waybar/hyprland-config.json -s ~/.config/waybar/style.css; fi'";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [
        "XDG_CONFIG_HOME=%h/.config"
      ];
    };
    Install = { WantedBy = [ "graphical-session.target" ]; };
  };

}
