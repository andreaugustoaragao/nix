{
  lib,
  hostName,
  ...
}:

{
  imports = [
    ./notes-sync.nix
    ./fulcrum.nix
    ./darkman.nix
  ]
  ++ lib.optionals (hostName == "workstation") [
    ./local-llm.nix
  ];
}
