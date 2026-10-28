{
  lib,
  pkgs,
  unstable-pkgs,
  ...
}:

let
  profiles = import ../../pkgs/browser-profiles.nix;
  browserTask = pkgs.callPackage ../../pkgs/browser-task.nix { };
  inherit (unstable-pkgs) chromium;

  launch =
    role: profile:
    pkgs.writeShellScript "agent-browser-${role}" ''
      set -eu
      data_home="''${XDG_DATA_HOME:-$HOME/.local/share}"
      profile_dir="$data_home/agent-browsers/${role}"
      ${pkgs.coreutils}/bin/install -d -m 0700 "$profile_dir"
      exec ${chromium}/bin/chromium \
        ${
          if profile.headless then "--headless" else "--ozone-platform=wayland --class=${profile.appId}"
        } \
        --password-store=gnome-libsecret \
        --no-first-run \
        --no-default-browser-check \
        --user-data-dir="$profile_dir" \
        --remote-debugging-address=127.0.0.1 \
        --remote-debugging-port=${toString profile.port} \
        about:blank
    '';

  service = role: profile: {
    Unit = {
      Description = "Agent browser (${role})";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${launch role profile}";
      Restart = "always";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
in
{
  home.packages = [ browserTask ];

  systemd.user.services =
    lib.mapAttrs' (
      role: profile: lib.nameValuePair "agent-browser-${role}" (service role profile)
    ) profiles
    // {
      agent-browser-cleanup = {
        Unit.Description = "Clean completed agent browser tabs";
        Service = {
          Type = "oneshot";
          ExecStart = "${browserTask}/bin/browser-task cleanup";
        };
      };
    };

  systemd.user.timers.agent-browser-cleanup = {
    Unit.Description = "Clean completed agent browser tabs every minute";
    Timer = {
      OnCalendar = "minutely";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  xdg.desktopEntries = lib.mapAttrs' (
    role: profile:
    lib.nameValuePair "agent-browser-${role}" {
      name = "Agent Browser (${role})";
      exec = "${browserTask}/bin/browser-task show --profile ${role}";
      terminal = false;
      type = "Application";
      categories = [ "Network" ];
      settings.StartupWMClass = profile.appId;
    }
  ) (lib.filterAttrs (_: profile: !profile.headless) profiles);
}
