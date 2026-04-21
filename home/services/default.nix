{
  config,
  pkgs,
  lib,
  hostName,
  ...
}:

{
  imports = [
    ./notes-sync.nix
    ./fulcrum.nix
  ]
  ++ lib.optionals (hostName != "workstation") [
    ./ollama.nix
  ];
}
