{
  pkgs,
  lib,
  appearance,
  ...
}:
let
  toolkit = import ./appearance/toolkit.nix { inherit lib appearance; };
  startSession = pkgs.writeShellScript "worker-graphical-ready" ''
    set -eu
    ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP
    ${pkgs.systemd}/bin/systemctl --user start worker-graphical-session.service
  '';
  swayConfig = pkgs.writeText "worker-sway.conf" ''
    output HEADLESS-1 resolution 1920x1080
    output * bg #202020 solid_color
    seat seat0 fallback true
    default_border pixel 2
    focus_follows_mouse no
    exec ${startSession}
  '';
in
{
  imports = [
    ./desktop/agent-browsers.nix
    ./desktop/gtk.nix
    ./desktop/qt.nix
  ];
  home.packages = [
    pkgs.sway-unwrapped
    pkgs.swaybg
    pkgs.wayvnc
    pkgs.grim
    pkgs.wl-clipboard
  ];
  home.sessionVariables = {
    WAYLAND_DISPLAY = "wayland-1";
    SWAYSOCK = "/run/user/1000/worker-sway.sock";
    DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
    XDG_CURRENT_DESKTOP = "sway";
    QT_QPA_PLATFORM = "wayland";
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    LIBGL_ALWAYS_SOFTWARE = "1";
  };
  systemd.user.services = {
    worker-desktop = {
      Unit.Description = "Private virtual desktop for agent browser and native GUI tests";
      Service = {
        Environment = [
          "WLR_BACKENDS=headless"
          "WLR_RENDERER=pixman"
          "WLR_HEADLESS_OUTPUTS=1"
          "XDG_CURRENT_DESKTOP=sway"
        ];
        ExecStart = "${pkgs.sway-unwrapped}/bin/sway --config ${swayConfig}";
        ExecStopPost = "${pkgs.systemd}/bin/systemctl --user stop worker-graphical-session.service";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "default.target" ];
    };
    worker-graphical-session = {
      Unit = {
        Description = "Activate services after the worker compositor is ready";
        BindsTo = [
          "graphical-session.target"
          "worker-desktop.service"
        ];
        Before = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
    };
    worker-desktop-view = {
      Unit = {
        Description = "Loopback-only worker desktop review";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = "${pkgs.wayvnc}/bin/wayvnc --config ${pkgs.writeText "worker-wayvnc.conf" "enable_auth=false\n"} --max-fps=20 127.0.0.1:5900";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
  services.gnome-keyring.enable = lib.mkForce false;
  xdg.configFile."gtk-3.0/gruvbox.css" = lib.mkIf appearance.isGruvbox { text = toolkit.dark.gtk3; };
  xdg.configFile."gtk-4.0/gruvbox.css" = lib.mkIf appearance.isGruvbox { text = toolkit.dark.gtk4; };
  xdg.configFile."gtk-2.0/gruvbox.rc" = lib.mkIf appearance.isGruvbox {
    text = "gtk-theme-name=\"Gruvbox-Dark\"\n";
  };
  xdg.configFile."environment.d/40-worker-desktop.conf".text = ''
    WAYLAND_DISPLAY=wayland-1
    SWAYSOCK=/run/user/1000/worker-sway.sock
    XDG_CURRENT_DESKTOP=sway
    QT_QPA_PLATFORM=wayland
    NIXOS_OZONE_WL=1
    LIBGL_ALWAYS_SOFTWARE=1
  '';
}
