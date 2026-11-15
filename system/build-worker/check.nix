{ pkgs, worker }:
let
  inherit (pkgs) lib;
  cfg = worker.config;
  hasSecrets = cfg.sops.secrets != { };
  installer = cfg.systemd.services.sops-install-secrets;
  identity = cfg.systemd.services.worker-identity;
  disabled =
    (worker.extendModules {
      modules = [ ({ lib, ... }: { sops.useSystemdActivation = lib.mkForce false; }) ];
    }).config;
  trusted =
    (worker.extendModules {
      modules = [ ({ lib, ... }: { nix.sshServe.trusted = lib.mkForce true; }) ];
    }).config;
  clientKeys = map (host: ../../secrets/workers/clients + "/cache-${host}.pub") [
    "prl-dev-vm"
    "workstation"
  ];
in
assert lib.assertMsg (
  !hasSecrets || (cfg.sops.useSystemdActivation && (installer.serviceConfig.ExecStart or [ ]) != [ ])
) "Enrolled worker credentials must have an executable systemd installation service.";
assert lib.assertMsg (
  identity.unitConfig.DefaultDependencies == false && builtins.elem "local-fs.target" identity.after
) "The persistent identity must be available before sysinit without an ordering cycle.";
assert lib.assertMsg (
  !hasSecrets
  || (
    builtins.elem "worker-identity.service" installer.requires
    && builtins.elem "worker-identity.service" installer.after
  )
) "Worker decryption must wait for its persistent identity.";
assert lib.assertMsg (
  !hasSecrets
  || lib.any (
    item: !item.assertion && lib.hasInfix "Worker credentials require systemd activation" item.message
  ) disabled.assertions
) "The original incomplete SOPS service must be rejected.";
assert lib.assertMsg (lib.all (
  path:
  !builtins.pathExists path
  || builtins.elem (lib.fileContents path) cfg.nix.settings.trusted-public-keys
) clientKeys) "The untrusted builder must accept signed inputs from its pinned clients.";
assert lib.assertMsg (lib.any (
  item: !item.assertion && lib.hasInfix "untrusted Nix clients" item.message
) trusted.assertions) "The builder account must not gain trusted Nix privileges.";
pkgs.runCommand "check-build-worker-credentials" { } ''
  touch "$out"
''
