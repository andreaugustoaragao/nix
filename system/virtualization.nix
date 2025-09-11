{ config, pkgs, lib, inputs, ... }:

{
  virtualisation.docker.enable = true;

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = "--disable traefik";
  };
} 