{ ... }:

# Clamshell-sleep override for mac-work.
#
# Companion to darwin/power.nix. That module disables idle system
# sleep on AC via `pmset -c sleep 0`, but Apple's hardware policy
# still forces clamshell sleep when the lid closes unless an
# external display + power + USB input device are all attached. In
# our setup the MacBook may sit lid-closed on the desk with nothing
# but power plugged in, while the dev VM keeps serving an agent
# over Telegram / Matrix — and clamshell sleep would kill it.
#
# `caffeinate -s` creates a kIOPMAssertPreventSystemSleep assertion,
# which overrides clamshell sleep (and any other PreventSystemSleep
# trigger) while AC is connected. The assertion auto-releases the
# moment the laptop switches to battery — so we still suspend
# normally when unplugged, no extra power-source watcher needed.
# This is the same primitive Amphetamine / KeepingYouAwake use; we
# just bind it to a LaunchDaemon so it survives reboots and logouts
# without a GUI app in the menu bar.
#
# Daemon (not user agent) because:
#   - we want it active before anyone logs in (lid-closed cold boot
#     into a remote SSH-only session must not sleep);
#   - the assertion is system-scoped — running as root is fine and
#     avoids tying liveness to a user session.
#
# KeepAlive=true relaunches the process if something (a stray
# `killall caffeinate`, an OOM, etc.) takes it down. ThrottleInterval
# guards against tight relaunch loops in pathological cases.
{
  launchd.daemons.caffeinate-ac = {
    serviceConfig = {
      Label = "net.faragao.caffeinate-ac";
      ProgramArguments = [
        "/usr/bin/caffeinate"
        "-s"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      # Silence stdout/stderr — `caffeinate -s` is a silent
      # foreground daemon; nothing useful to log. Pointing both
      # at /dev/null avoids growing files under /var/log.
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
}
