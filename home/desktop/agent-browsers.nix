{
  lib,
  pkgs,
  unstable-pkgs,
  ...
}:

let
  profiles = import ../../pkgs/browser-profiles.nix;
  browserTask = pkgs.callPackage ../../pkgs/browser-task.nix { };
  browserAssist = pkgs.callPackage ../../pkgs/browser-assist.nix {
    zig = unstable-pkgs.zig_0_17;
    browser-task = browserTask;
  };
  chromium = import ../../pkgs/chromium-ahead.nix {
    inherit (pkgs) lib;
    inherit (unstable-pkgs) chromium;
  };

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
        --hide-crash-restore-bubble \
        --password-store=gnome-libsecret \
        --no-first-run \
        --no-default-browser-check \
        --user-data-dir="$profile_dir" \
        --remote-debugging-address=127.0.0.1 \
        --remote-debugging-port=${toString profile.port} \
        about:blank
    '';

  browserMode = pkgs.writeShellApplication {
    name = "agent-browser-mode";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      if [[ $# != 2 ]]; then
        echo 'Usage: agent-browser-mode accounts|development visible|headless' >&2
        exit 2
      fi
      role=$1
      mode=$2
      case "$role:$mode" in
        ${lib.concatStringsSep "\n" (
          lib.concatMap (
            role:
            map
              (
                mode:
                let
                  isDefault = (mode == "headless") == profiles.${role}.headless;
                  profile = profiles.${role} // {
                    headless = mode == "headless";
                  };
                  modeProfiles = profiles // {
                    ${role} = profile;
                  };
                in
                ''
                  ${role}:${mode})
                    is_default=${lib.boolToString isDefault}
                    launcher=${launch role profile}
                    profile_config=${pkgs.writeText "browser-profiles-${role}-${mode}.json" (builtins.toJSON modeProfiles)}
                    ;;
                ''
              )
              [
                "visible"
                "headless"
              ]
          ) (builtins.attrNames profiles)
        )}
        *) echo 'Expected accounts|development and visible|headless' >&2; exit 2 ;;
      esac

      : "''${XDG_RUNTIME_DIR:?A desktop user session is required}"
      umask 077
      mode_dir="$XDG_RUNTIME_DIR/agent-browser-mode/$role"
      unit="agent-browser-$role.service"
      override_dir="$XDG_RUNTIME_DIR/systemd/user/$unit.d"
      override="$override_dir/90-agent-browser-mode.conf"
      install -d -m 0700 "$mode_dir" "$override_dir"
      exec 9>"$mode_dir/lock"
      flock 9

      restarted=true
      if systemctl --user is-active --quiet "$unit" &&
        [[ $(systemctl --user show --property=ExecStart --value "$unit") == *"path=$launcher ;"* ]]; then
        restarted=false
      fi

      if [[ $is_default == true ]]; then
        rm -f "$override"
        rmdir --ignore-fail-on-non-empty "$override_dir" 2>/dev/null || true
      else
        pending=$(mktemp "$override_dir/.browser-mode.XXXXXX")
        trap 'rm -f "$pending"' EXIT
        printf '[Service]\nExecStart=\nExecStart=%s\n' "$launcher" > "$pending"
        mv "$pending" "$override"
      fi
      install -m 0600 "$profile_config" "$mode_dir/profiles.json"
      systemctl --user daemon-reload
      if [[ $restarted == true ]]; then
        systemctl --user restart "$unit"
      fi
      jq -cn --arg profile "$role" --arg mode "$mode" \
        --arg config "$mode_dir/profiles.json" --argjson restarted "$restarted" \
        '{profile: $profile, mode: $mode, config: $config, restarted: $restarted}'
    '';
  };

  service = role: profile: {
    Unit = {
      Description = "Agent browser (${role})";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Slice = "background.slice";
      OOMScoreAdjust = 300;
      ExecStart = "${launch role profile}";
      Restart = "always";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
in
{
  home.packages = [
    browserTask
    browserAssist
    browserMode
  ];

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

  xdg.desktopEntries = {
    browser-assist = {
      name = "Browser assistance";
      exec = "${browserAssist}/bin/browser-assist";
      terminal = false;
      type = "Application";
      categories = [ "Network" ];
    };
  }
  // lib.mapAttrs' (
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
