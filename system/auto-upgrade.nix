{
  config,
  pkgs,
  lib,
  owner,
  isServer,
  ...
}:

let
  flakeUrl = "github:andreaugustoaragao/nix";

  # Compose a libnotify message body from `nvd diff` between the two
  # most recent system generations and send it to the logged-in user
  # via their session DBus. Mirrors the notification helper in
  # system/nix.nix. Failures are non-fatal — the upgrade unit must
  # not flip to "failed" because the desktop session was absent.
  upgradeNotify = pkgs.writeShellScript "nixos-upgrade-notify" ''
    set -uo pipefail

    status="''${1:-success}"

    gens=$(${pkgs.coreutils}/bin/ls -1 /nix/var/nix/profiles/ \
      | ${pkgs.gnugrep}/bin/grep -E '^system-[0-9]+-link$' \
      | ${pkgs.coreutils}/bin/sort -V \
      | ${pkgs.coreutils}/bin/tail -2)
    prev=$(echo "$gens" | ${pkgs.coreutils}/bin/head -1)
    curr=$(echo "$gens" | ${pkgs.coreutils}/bin/tail -1)

    if [[ -z "$prev" || -z "$curr" || "$prev" == "$curr" ]]; then
      diff_text="(no previous generation to compare)"
    else
      diff_text=$(NO_COLOR=1 ${pkgs.nvd}/bin/nvd diff \
        "/nix/var/nix/profiles/$prev" "/nix/var/nix/profiles/$curr" 2>&1 \
        || echo "(diff failed)")
    fi

    # Keep the notification body short — full diff stays in journald.
    summary=$(echo "$diff_text" | ${pkgs.coreutils}/bin/head -20)

    if [[ "$status" == "fail" ]]; then
      title="❌ NixOS Auto-Upgrade Failed"
      urgency="critical"
      body="Check journalctl -u nixos-upgrade"
    else
      title="✅ NixOS Auto-Upgrade Complete"
      urgency="normal"
      body="$summary"
    fi

    user="${owner.name}"
    uid=$(${pkgs.coreutils}/bin/id -u "$user")
    user_bus="unix:path=/run/user/''${uid}/bus"

    if [ -S "/run/user/''${uid}/bus" ]; then
      ${pkgs.util-linux}/bin/runuser -u "$user" -- \
        ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="$user_bus" \
        ${pkgs.libnotify}/bin/notify-send \
          --app-name="NixOS Auto-Upgrade" \
          --urgency="$urgency" \
          "$title" "$body" || true
    fi
  '';
in
{
  system.autoUpgrade = {
    enable = true;
    flake = flakeUrl;
    flags = [
      "--refresh"
      "-L"
    ];
    operation = "switch";
    dates = if isServer then "Sun 03:00" else "*-*-1/2 02:00:00";
    randomizedDelaySec = "30min";
    # Servers benefit from missed-run recovery (Persistent=true). Desktops
    # must NOT — past-due slots fire immediately on first activation, and
    # if the working tree has uncommitted changes the auto-upgrade pulls
    # GitHub main and rolls the live system back. (This bit us once.)
    persistent = isServer;
  };

  systemd.services.nixos-upgrade = lib.mkIf (!isServer) {
    serviceConfig.ExecStartPost = [ "-${upgradeNotify} success" ];
    onFailure = [ "nixos-upgrade-notify-fail.service" ];
  };

  systemd.services.nixos-upgrade-notify-fail = lib.mkIf (!isServer) {
    description = "Desktop notification on nixos-upgrade failure";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${upgradeNotify} fail";
    };
  };
}
