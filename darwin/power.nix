{ lib, ... }:

# AC power policy for mac-work.
#
# Goal: keep the Mac awake whenever it's plugged in, so the
# development VM (Parallels) — which hosts an agent reachable
# remotely over Telegram and Matrix — stays responsive while the lid
# is closed or the office is empty. Display sleep is fine; only
# system sleep on AC is disabled.
#
# Battery behavior is intentionally left untouched. Stock macOS
# defaults (sleep ~1 min, displaysleep ~2 min) keep the laptop from
# draining when unplugged. If you need the VM reachable on battery
# too, plug it in.
#
# Why not nix-darwin's `power.sleep.computer = "never"`?
#   Upstream's modules/power/sleep.nix drives `systemsetup
#   -setComputerSleep`, which writes the same value to every power
#   source (AC, battery, UPS). That would disable battery sleep too
#   and shorten battery life dramatically. We need AC-only
#   granularity, and only `pmset -c` exposes it — so we extend the
#   existing `power` activation script with mkAfter rather than
#   introducing a new key under system.activationScripts (custom
#   keys aren't wired into the master activator in
#   modules/system/activation-scripts.nix).
{
  system.activationScripts.power.text = lib.mkAfter ''
    /usr/bin/pmset -c sleep 0
  '';
}
