{ pkgs, workstation }:
let
  inherit (pkgs) lib;
  failures =
    module:
    let
      cfg = (workstation.extendModules { modules = [ module ]; }).config;
    in
    map (item: item.message) (builtins.filter (item: !item.assertion) cfg.assertions);
  rejects = fragment: module: lib.any (lib.hasInfix fragment) (failures module);
in
assert lib.assertMsg (rejects "passwordless rules are prohibited" (
  { lib, ... }: {
    security.sudo.extraConfig = lib.mkAfter "\naragao ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild\n";
  }
)) "The original passwordless activation bypass must stay rejected.";
assert lib.assertMsg (rejects "authenticated operator" (
  { lib, ... }: {
    system.autoUpgrade.enable = lib.mkForce true;
  }
)) "Unattended workstation activation must stay rejected.";
assert lib.assertMsg (rejects "must not control the rootful socket" (
  { lib, ... }: {
    users.users.aragao.extraGroups = lib.mkAfter [ "docker" ];
  }
)) "Rootful Docker membership must stay rejected.";
assert lib.assertMsg (rejects "host K3s must be disabled" (
  { lib, ... }: {
    my.workstation.kubernetes.mode = "guest";
    services.k3s.enable = lib.mkForce true;
  }
)) "The desktop and guest must not both run the migrated cluster.";
pkgs.runCommand "check-workstation-security" { } ''
  touch "$out"
''
