{ config, pkgs, lib, ... }:

{
  imports = [
    ./notes-sync.nix
    ./ollama.nix
  ];
}