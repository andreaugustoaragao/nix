{ config, pkgs, lib, ... }:

{
  imports = [
    ./bw-query.nix
    ./browser-default.nix
    ./browser-app.nix
  ];
}