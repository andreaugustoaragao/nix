{ config, pkgs, lib, inputs, ... }:

{
  virtualisation.docker.enable = true;

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = "--disable traefik";
  };

  # Lazy-load K3s: Remove from critical boot path and start after graphical session
  systemd.services.k3s = {
    wantedBy = lib.mkForce [ ];  # Remove from multi-user.target dependency
    after = [ "graphical-session.target" ];  # Start after graphical session
    requisite = [ "network-online.target" ];  # Still require network
  };

  # Create a delayed K3s startup service
  systemd.services.k3s-lazy = {
    description = "Lazy-load K3s after graphical session";
    after = [ "graphical.target" ];
    wantedBy = [ "graphical.target" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "60s";
    };
    # Add a delay to not interfere with desktop startup
    script = ''
      echo "Starting K3s lazy-load in 30 seconds..."
      sleep 30  # Wait 30 seconds after graphical.target
      echo "Starting K3s service..."
      ${pkgs.systemd}/bin/systemctl start k3s.service
    '';
  };
} 