{ config, pkgs, lib, inputs, hostName, ... }:

{
  virtualisation.docker.enable = true;

  # Lazy-load Docker: Remove from critical boot path and start after graphical session
  systemd.services.docker = {
    wantedBy = lib.mkForce [ ];  # Remove from multi-user.target dependency
    after = [ "graphical.target" ];  # Start after graphical target
    requisite = [ "network-online.target" ];  # Still require network
  };

  # Create a delayed Docker startup service
  systemd.services.docker-lazy = {
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

  # K3s configuration - disabled for hp-laptop
  services.k3s = lib.mkIf (hostName != "hp-laptop") {
    enable = true;
    role = "server";
    extraFlags = "--disable traefik";
  };

  # Lazy-load K3s: Remove from critical boot path and start after graphical session
  systemd.services.k3s = lib.mkIf (hostName != "hp-laptop") {
    wantedBy = lib.mkForce [ ];  # Remove from multi-user.target dependency
    after = [ "graphical-session.target" ];  # Start after graphical session
    requisite = [ "network-online.target" ];  # Still require network
  };

  # Create a delayed K3s startup service
  systemd.services.k3s-lazy = lib.mkIf (hostName != "hp-laptop") {
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