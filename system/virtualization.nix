{
  pkgs,
  lib,
  hostName,
  ...
}:

{
  virtualisation.docker.enable = true;

  systemd = {
    # Cap any stuck unit's stop phase so a single hung service can't
    # block shutdown long enough to trigger the watchdog hang we hit
    # with k3s+docker (orphaned containerd-shims holding CNI netns
    # mounts open until SIGKILL).
    settings.Manager.DefaultTimeoutStopSec = "30s";

    services = {
      # Lazy-load Docker: removed from the boot transaction via
      # `wantedBy = mkForce [ ]`, then explicitly started ~15s after
      # graphical.target by docker-lazy.service below.
      #
      # We deliberately do NOT add `after = [ "graphical.target" ]` here:
      # combined with silence-log-martians.service (After=docker.service,
      # WantedBy=multi-user.target) and the standard multi-user→graphical
      # ordering, that creates a cycle systemd resolves by dropping
      # docker.service/start from the boot transaction. The socket then
      # comes up without the daemon, and any oci-container pulled in by
      # multi-user.target (e.g. docker-chroma.service) hard-fails before
      # docker-lazy can rescue it.
      docker = {
        wantedBy = lib.mkForce [ ]; # Remove from multi-user.target dependency
        requisite = [ "network-online.target" ]; # Still require network
        serviceConfig = {
          # Default is KillMode=process which only kills dockerd itself,
          # leaving containerd-shim and container processes orphaned —
          # they then survive into systemd-shutdown's final phase and
          # block CNI netns unmounts. mixed: SIGTERM the main process,
          # then SIGKILL the rest of the cgroup after the timeout.
          KillMode = lib.mkForce "mixed";
          TimeoutStopSec = lib.mkForce "30s";
        };
      };

      # Create a delayed Docker startup service
      docker-lazy = {
        description = "Lazy-load Docker after graphical session";
        after = [ "graphical.target" ];
        wantedBy = [ "graphical.target" ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "60s";
        };
        # Add a delay to not interfere with desktop startup
        script = ''
          echo "Starting Docker lazy-load in 15 seconds..."
          sleep 15  # Wait 15 seconds after graphical.target
          echo "Starting Docker service..."
          ${pkgs.systemd}/bin/systemctl start docker.service
        '';
      };

      # Lazy-load K3s: Remove from critical boot path and start after graphical session
      k3s = lib.mkIf (hostName != "hp-laptop") {
        wantedBy = lib.mkForce [ ]; # Remove from multi-user.target dependency
        after = [ "graphical-session.target" ]; # Start after graphical session
        requisite = [ "network-online.target" ]; # Still require network
        serviceConfig = {
          # Same pattern as docker — kill the whole cgroup, not just the
          # main process. Without this, containerd-shim, tini, and pod
          # processes survive k3s.service stop and hold /run/netns/cni-*
          # mounts open through systemd-shutdown's umount phase.
          KillMode = lib.mkForce "mixed";
          TimeoutStopSec = lib.mkForce "30s";
          # Best-effort cleanup before SIGKILL: drop containerd-shim
          # processes and unmount the CNI netns paths that block shutdown.
          # `+` prefix runs as root regardless of unit User=.
          ExecStop = [
            "+${pkgs.writeShellScript "k3s-shutdown-cleanup" ''
              set +e
              ${pkgs.procps}/bin/pkill -TERM -f containerd-shim 2>/dev/null
              sleep 1
              ${pkgs.procps}/bin/pkill -KILL -f containerd-shim 2>/dev/null
              for ns in /run/netns/cni-*; do
                [ -e "$ns" ] || continue
                ${pkgs.util-linux}/bin/umount "$ns" 2>/dev/null
                rm -f "$ns" 2>/dev/null
              done
              ${pkgs.util-linux}/bin/umount -R /var/lib/kubelet/pods 2>/dev/null
              ${pkgs.util-linux}/bin/umount -R /run/k3s 2>/dev/null
              exit 0
            ''}"
          ];
        };
      };

      # Create a delayed K3s startup service
      k3s-lazy = lib.mkIf (hostName != "hp-laptop") {
        description = "Lazy-load K3s after graphical session";
        after = [ "graphical.target" ];
        wantedBy = [ "graphical.target" ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "60s";
        };
        # Add a delay to not interfere with desktop startup.
        # --no-block: enqueue the start and return immediately. k3s
        # takes longer to activate than this wrapper's TimeoutStartSec,
        # so blocking here would make the wrapper time out even though
        # k3s itself starts fine. k3s.service tracks its own status.
        script = ''
          echo "Starting K3s lazy-load in 30 seconds..."
          sleep 30  # Wait 30 seconds after graphical.target
          echo "Starting K3s service..."
          ${pkgs.systemd}/bin/systemctl start --no-block k3s.service
        '';
      };
    };
  };

  # K3s configuration - disabled for hp-laptop
  services.k3s = lib.mkIf (hostName != "hp-laptop") (
    let
      nodeIp =
        if hostName == "prl-dev-vm" then
          "10.211.55.4"
        else if hostName == "workstation" then
          "192.168.10.75"
        else
          null;
      ipFlags = lib.optionalString (nodeIp != null) " --node-ip ${nodeIp} --tls-san ${nodeIp}";
      # mDNS-published name (see system/mdns.nix). Adding it as a SAN
      # lets remote clients reach kube-apiserver via `https://<host>.local:6443`
      # without TLS verification errors — the form `nix run .#peers-kube-fetch`
      # produces. The short name is included for parity with how the
      # SSH client config refers to the host.
      hostSan = " --tls-san ${hostName}.local --tls-san ${hostName}";
    in
    {
      enable = true;
      role = "server";
      extraFlags = "--disable traefik --write-kubeconfig-mode 0644${ipFlags}${hostSan}";
    }
  );
}
