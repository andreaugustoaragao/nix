{ pkgs, ... }:

# Office-hours display policy for mac-work.
#
# 08:00–18:00 the desktop stays available: `caffeinate -d -s` holds
# the displays on and blocks clamshell/system sleep while AC is
# connected. macOS locks the session when the display sleeps, so
# holding the panels on is what keeps the workday unlocked.
#
# Outside that window the assertion is dropped, the console session
# is locked, and the displays are put to sleep. The check uses the
# wall clock, so a sleep/wake in the middle of the day still ends at
# 18:00 instead of running for a fixed ten hours from process start.
# Idle system sleep on AC stays disabled in darwin/power.nix, so the
# dev VM keeps running with the lid open and the panels dark.
# Battery idle sleep is untouched.
#
# Companion to darwin/power.nix. `pmset -c sleep 0` disables idle
# system sleep on AC, but Apple's hardware policy still forces
# clamshell sleep when the lid closes unless an external display +
# power + USB input device are all attached. In our setup the
# MacBook may sit lid-closed on the desk with nothing but power
# plugged in, while the dev VM keeps serving an agent over Telegram
# / Matrix. `caffeinate -s` is the clamshell override, and it
# auto-releases on battery.
#
# Daemon (not user agent) because:
#   - it must be active before anyone logs in (lid-closed cold boot
#     into a remote SSH-only session must not sleep during the
#     workday);
#   - the assertion is system-scoped — running as root is fine and
#     avoids tying liveness to a user session.
let
  startHour = 8;
  endHour = 18;

  officeHours = pkgs.writeShellScript "caffeinate-office-hours" ''
    start_hour=${toString startHour}
    end_hour=${toString endHour}
    lock_app="/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app"
    caffeinate_pid=

    in_office_hours() {
      hour="$((1$(/bin/date +%H) - 100))"
      [ "$hour" -ge "$start_hour" ] && [ "$hour" -lt "$end_hour" ]
    }

    stop_caffeinate() {
      if [ -n "$caffeinate_pid" ]; then
        /bin/kill "$caffeinate_pid" 2>/dev/null || true
        /bin/wait "$caffeinate_pid" 2>/dev/null || true
        caffeinate_pid=
      fi
    }

    # SIGTERM is a launchd unload (darwin-rebuild). Release the
    # assertion without locking; the reloaded job decides again.
    trap 'stop_caffeinate; exit 0' TERM INT

    lock_and_disable_displays() {
      console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
      case "$console_user" in
        "" | root | loginwindow) ;;
        *)
          # `open` hands the app to the console session and returns.
          # LockScreen asks loginwindow to lock; it needs no
          # Accessibility permission, unlike a synthetic Ctrl-Cmd-Q.
          /usr/bin/open "$lock_app" >/dev/null 2>&1 || true
          ;;
      esac
      /bin/sleep 1
      /usr/bin/pmset displaysleepnow || true
    }

    if in_office_hours; then
      /usr/bin/caffeinate -d -s &
      caffeinate_pid=$!

      while in_office_hours; do
        /bin/sleep 15
        if in_office_hours && ! /bin/kill -0 "$caffeinate_pid" 2>/dev/null; then
          /usr/bin/caffeinate -d -s &
          caffeinate_pid=$!
        fi
      done

      stop_caffeinate
    fi

    lock_and_disable_displays
    exit 0
  '';
in
{
  launchd.daemons.caffeinate-ac = {
    serviceConfig = {
      Label = "net.faragao.caffeinate-ac";
      ProgramArguments = [ "${officeHours}" ];
      StartCalendarInterval = [
        {
          Hour = startHour;
          Minute = 0;
        }
        {
          Hour = endHour;
          Minute = 0;
        }
      ];

      # Boot or rebuild during the workday starts the assertion.
      # Outside the window the script locks and sleeps the displays.
      RunAtLoad = true;

      # A crash during the workday should come back. The 18:00 path
      # exits 0 on purpose so it does not lock again every few seconds.
      KeepAlive = {
        SuccessfulExit = false;
      };
      ThrottleInterval = 10;

      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
}
