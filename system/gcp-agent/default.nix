{
  config,
  lib,
  pkgs,
  owner,
  hostName,
  stateVersion,
  ...
}:
let
  idleThresholdMinutes = 60;
  idleCheckIntervalMinutes = 5;
  idleLimit = idleThresholdMinutes / idleCheckIntervalMinutes;

  herdrCore = pkgs.callPackage ../../pkgs/herdr-core.nix { };

  idleCheck = pkgs.writeShellApplication {
    name = "gcp-idle-shutdown-check";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      # herdrCore invoked via absolute store path under runuser below.
      procps
      python3
      systemd
      util-linux
    ];
    text = ''
      set -euo pipefail

      state_file="/run/gcp-agent-idle-count"

      if [[ -e /run/no-idle-shutdown || -e /var/lib/gcp-agent/no-idle-shutdown ]]; then
        rm -f "$state_file"
        exit 0
      fi

      uptime_sec=$(awk '{print int($1)}' /proc/uptime)
      if (( uptime_sec < 2700 )); then
        rm -f "$state_file"
        exit 0
      fi

      busy=0
      now=$(date +%s)
      for pts in /dev/pts/[0-9]*; do
        [[ -e "$pts" ]] || continue
        mtime=$(stat -c %Y "$pts" 2>/dev/null || echo 0)
        if (( now - mtime < 300 )); then
          busy=1
          break
        fi
      done

      if (( busy == 0 )); then
        uid=$(id -u ${lib.escapeShellArg owner.name})
        hc_sock="/run/user/$uid/herdr-core/default.sock"
        if [[ -S "$hc_sock" ]]; then
          hc_rc=0
          hc_out=$(runuser -u ${lib.escapeShellArg owner.name} -- env HC_SOCKET="$hc_sock" ${lib.getExe herdrCore} ls --json 2>/dev/null) || hc_rc=$?
          if (( hc_rc == 0 )); then
            py_rc=0
            python3 -c '
      import json, sys
      try:
          data = json.load(sys.stdin)
      except Exception:
          sys.exit(2)
      if not isinstance(data, dict) or "error" in data or not isinstance(data.get("terminals"), list):
          sys.exit(2)
      def is_working(t):
          if not isinstance(t, dict) or t.get("state") != "live" or "/" in (t.get("address") or ""):
              return False
          st = t.get("status")
          if isinstance(st, dict):
              st = st.get("state")
          return st == "working"
      sys.exit(0 if any(is_working(t) for t in data["terminals"]) else 1)
      ' <<< "$hc_out" || py_rc=$?
          else
            py_rc=2
          fi
          case "$py_rc" in
            0)
              busy=1
              ;;
            1)
              ;;
            *)
              if pgrep -u ${lib.escapeShellArg owner.name} -f 'herdr-core(-wrapped)? serve($| )' >/dev/null 2>&1; then
                echo "Herdr status query failed (hc_rc=$hc_rc, py_rc=$py_rc) while herdr-core is running; treating VM as busy." >&2
                busy=1
              fi
              ;;
          esac
        fi
      fi

      if (( busy == 0 )) && pgrep -u ${lib.escapeShellArg owner.name} -x 'cargo|rustc|nix|nix-build|go|make' >/dev/null 2>&1; then
        busy=1
      fi

      if (( busy == 0 )) && awk '{ exit ($2 >= 0.35) ? 0 : 1 }' /proc/loadavg; then
        busy=1
      fi
      if (( busy == 1 )); then
        rm -f "$state_file"
        exit 0
      fi

      count=0
      if [[ -f "$state_file" ]]; then
        count=$(cat "$state_file" 2>/dev/null || echo 0)
      fi
      count=$((count + 1))
      printf '%s\n' "$count" > "$state_file"

      if (( count >= ${toString idleLimit} )); then
        echo "Idle for $((count * ${toString idleCheckIntervalMinutes}))m with no SSH, agent, or build activity; powering off."
        rm -f "$state_file"
        exec systemctl poweroff
      fi
    '';
  };

  keepAwake = pkgs.writeShellApplication {
    name = "gcp-keep-awake";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      flag="/run/no-idle-shutdown"
      case "''${1:-status}" in
        on)
          touch "$flag"
          rm -f /run/gcp-agent-idle-count
          echo "Idle auto-shutdown inhibited ($flag)."
          ;;
        off)
          rm -f "$flag"
          echo "Idle auto-shutdown enabled."
          ;;
        status)
          if [[ -e "$flag" || -e /var/lib/gcp-agent/no-idle-shutdown ]]; then
            echo "inhibited"
          else
            count=$(cat /run/gcp-agent-idle-count 2>/dev/null || echo 0)
            echo "enabled (idle checks: ''${count}/${toString idleLimit})"
          fi
          ;;
        *)
          echo "Usage: gcp-keep-awake [on|off|status]" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  imports = [
    ../nix.nix
    ../packages.nix
    ../nvim.nix
    ../env.nix
    ../ssh.nix
  ];

  sops = {
    defaultSopsFile = ../../secrets/gcp/gcp-agent-wk.yaml;
    validateSopsFiles = true;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      "litellm_base_url" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
        restartUnits = [ "home-manager-${owner.name}.service" ];
      };
      "litellm_api_key" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
        restartUnits = [ "home-manager-${owner.name}.service" ];
      };
      "git_email_work" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
        restartUnits = [ "home-manager-${owner.name}.service" ];
      };
    };
  };

  nixpkgs.config.allowUnfree = true;

  # Override nix.nix workstation/matrix defaults for cloud VM.
  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];
  systemd.services.nix-gc.onFailure = lib.mkForce [ ];

  # GCE networking: C4A uses gve (gVNIC) on enp0s0 with 1460 MTU and DHCP.
  networking = {
    inherit hostName;
    useDHCP = false;
    interfaces.enp0s0 = {
      useDHCP = true;
      mtu = 1460;
    };
    extraHosts = ''
      169.254.169.254 metadata.google.internal metadata
    '';
    timeServers = [ "metadata.google.internal" ];
    firewall.enable = true;
  };

  services.resolved.enable = true;
  services.timesyncd.enable = true;
  services.dbus.enable = true;

  # GCE guest integration (metadata SSH/startup/shutdown, disk udev rules).
  services.udev.packages = [ pkgs.google-guest-configs ];
  services.udev.path = [ pkgs.google-guest-configs ];
  environment.etc."modprobe.d/gce-blacklist.conf".source =
    "${pkgs.google-guest-configs}/etc/modprobe.d/gce-blacklist.conf";
  environment.etc."sysctl.d/60-gce-network-security.conf".source =
    "${pkgs.google-guest-configs}/etc/sysctl.d/60-gce-network-security.conf";
  environment.etc."default/instance_configs.cfg".text = ''
    [InstanceSetup]
    set_host_keys = false

    [NetworkInterfaces]
    setup = false
  '';
  systemd.packages = [ pkgs.google-guest-agent ];
  systemd.services.google-guest-agent = {
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ config.environment.etc."default/instance_configs.cfg".source ];
  };

  # Serial console for GCE serial port debugging.
  boot.kernelParams = [ "console=ttyAMA0,115200n8" ];

  # Allow local SSH port/socket forwarding over IAP tunnel for agent tooling.
  services.openssh.settings = {
    AllowTcpForwarding = lib.mkForce "local";
    AllowStreamLocalForwarding = lib.mkForce "local";
  };

  users.users.${owner.name} = {
    isNormalUser = true;
    linger = true;
    description = owner.fullName;
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL+ZJ5BDn32O6G/ZKaKahrW2SMY2frAjlTBMGwiF+xb+ aragao@gcp-agent-wk"
    ];
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  programs = {
    zsh.enable = true;
    command-not-found.enable = false;
    nix-index = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      enableFishIntegration = true;
    };
    nix-index-database.comma.enable = true;
  };

  virtualisation.docker.enable = true;

  environment.systemPackages = [
    keepAwake
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/gcp-agent 0755 root root -"
  ];

  systemd.services.gcp-idle-shutdown = {
    description = "Shut down GCP agent VM after idle timeout";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe idleCheck;
    };
  };

  systemd.timers.gcp-idle-shutdown = {
    description = "Check for GCP agent VM idleness";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "45min";
      OnUnitActiveSec = "${toString idleCheckIntervalMinutes}min";
      Unit = "gcp-idle-shutdown.service";
    };
  };

  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";
  system.stateVersion = stateVersion;
}
