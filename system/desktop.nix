{
  pkgs,
  lib,
  unstable-pkgs,
  ...
}:

{
  programs = {
    # Hyprland compositor
    hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    niri = {
      enable = true;
      package = unstable-pkgs.niri;
    };

    dconf.enable = true;
  };

  environment = {
    systemPackages = with pkgs; [ xwayland-satellite ];
    sessionVariables = {
      WLR_NO_HARDWARE_CURSORS = "0";
    };
  };

  # Screen sharing on niri requires xdg-desktop-portal-gnome to handle
  # the ScreenCast/RemoteDesktop interfaces (gtk's portal doesn't
  # implement them). Two pieces are needed:
  #
  #   1. Tell xdg-desktop-portal which backend handles each interface
  #      on niri. Without this, the .portal files' UseIn=gnome guards
  #      mean nothing auto-loads on a niri session.
  #
  #   2. Arm graphical-session.target. niri runs directly inside the
  #      logind session-N.scope (not via niri.service — see
  #      system/display-manager.nix for why), so the target is never
  #      activated by niri.service's BindsTo, and the gnome portal's
  #      Requisite=graphical-session.target makes its D-Bus activation
  #      fail. The bridge service below mirrors what niri.service
  #      would do for the target lifecycle, without actually wrapping
  #      niri in a user-systemd service. niri.nix starts the bridge
  #      via spawn-at-startup at compositor launch.
  xdg.portal.config.niri = {
    default = [
      "gnome"
      "gtk"
    ];
    "org.freedesktop.impl.portal.ScreenCast" = [ "gnome" ];
    "org.freedesktop.impl.portal.RemoteDesktop" = [ "gnome" ];
    "org.freedesktop.impl.portal.Screenshot" = [ "gnome" ];
  };

  systemd = {
    user.services.niri-graphical-session = {
      description = "Pull graphical-session.target up for niri (started outside niri.service)";
      bindsTo = [ "graphical-session.target" ];
      before = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
    };

    # SwayOSD LibInput backend needs to run as system service for proper D-Bus access
    services.swayosd-libinput-backend = {
      description = "SwayOSD LibInput backend for input device events";
      wantedBy = [ "multi-user.target" ];
      after = [ "dbus.service" ];
      requires = [ "dbus.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.swayosd}/bin/swayosd-libinput-backend";
        Restart = "on-failure";
        RestartSec = 2;
        User = "root";
        Group = "input";
      };
    };
  };

  services = {
    upower.enable = true;
    power-profiles-daemon.enable = true;
    fwupd.enable = true;

    flatpak.enable = lib.mkForce false;

    # SwayOSD D-Bus policy (required for libinput backend)
    dbus.packages = [ pkgs.swayosd ];
  };
}
