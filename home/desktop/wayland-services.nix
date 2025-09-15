{ config, pkgs, lib, inputs, ... }:

{
  # Generic Wayland session services (start when a Wayland compositor is running)
  systemd.user.services.wl-mako = {
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

  systemd.user.services.wl-swayosd = {
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


  systemd.user.services.wl-hyprpaper = {
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

  # Start polkit authentication agent in user session (needed outside GNOME)
  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    Unit = {
      Description = "polkit-gnome-authentication-agent-1";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
      RestartSec = 1;
      TimeoutStopSec = 10;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}