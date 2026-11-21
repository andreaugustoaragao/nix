{
  config,
  lib,
  pkgs,
  owner,
  hostName,
  ...
}:
let
  hostKey = ../secrets/workers + "/host-ed25519.pub";
  cacheKey = ../secrets/workers + "/cache.pub";
  ready = builtins.pathExists hostKey && builtins.pathExists cacheKey;
  signing = pkgs.callPackage ../pkgs/workstation-build-client-identity.nix { };
  clientKey = ../secrets/workers/clients + "/cache-${hostName}.pub";
  builder = {
    hostName = "workstation-worker-builder";
    protocol = "ssh-ng";
    sshUser = "nix-ssh";
    sshKey = "/home/${owner.name}/.ssh/id_ed25519_nix_workstation_worker";
    maxJobs = 2;
    speedFactor = 4;
  };
in
{
  config = lib.mkIf ready {
    environment.systemPackages = [ signing.client ];
    system.activationScripts.workstationBuildClientIdentity = ''
      public_key=$(${signing.initialise})
      ${lib.optionalString (builtins.pathExists clientKey) ''
        if [ "$public_key" != ${lib.escapeShellArg (lib.fileContents clientKey)} ]; then
          echo 'Build-client signing identity differs from its pinned public key; restore or rotate it explicitly.' >&2
          exit 1
        fi
      ''}
    '';
    systemd.services.workstation-build-client-sign = {
      description = "Sign existing Nix paths for the untrusted remote builder";
      wantedBy = [ "multi-user.target" ];
      after = [ "nix-daemon.service" ];
      requires = [ "nix-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        TimeoutStartSec = "15min";
        Nice = 10;
        CPUWeight = 50;
        IOWeight = 50;
      };
      script = ''
        set -eu
        public_key=$(${config.nix.package}/bin/nix key convert-secret-to-public < ${signing.secretKey})
        if [ ! -e ${signing.stateDirectory}/initial-store-signed ] \
          || [ "$(${pkgs.coreutils}/bin/cat ${signing.stateDirectory}/initial-store-signed)" != "$public_key" ]; then
          ${config.nix.package}/bin/nix store sign --all --key-file ${signing.secretKey}
          printf '%s\n' "$public_key" > ${signing.stateDirectory}/initial-store-signed
        fi
      '';
    };
    nix.distributedBuilds = true;
    nix.buildMachines = [
      (
        builder
        // {
          systems = [ "x86_64-linux" ];
          supportedFeatures = [
            "big-parallel"
            "kvm"
          ];
        }
      )
      (
        builder
        // {
          systems = [ "aarch64-linux" ];
          supportedFeatures = [ "big-parallel" ];
        }
      )
    ];
    nix.settings = {
      secret-key-files = [ signing.secretKey ];
      builders-use-substitutes = true;
      trusted-public-keys = [ (lib.fileContents cacheKey) ];
    };
    programs.ssh = {
      knownHosts.workstation-worker = {
        hostNames = [
          "workstation-worker"
          "[workstation-worker]:2222"
          "[192.168.10.75]:2222"
        ];
        publicKey = lib.fileContents hostKey;
      };
      extraConfig = ''
        Host workstation-worker-builder
          HostName 192.168.10.75
          Port 2222
          User nix-ssh
          HostKeyAlias workstation-worker
          StrictHostKeyChecking yes
          IdentitiesOnly yes
      '';
    };
    home-manager.users.${owner.name}.programs.ssh.settings.workstation-worker = {
      HostName = "192.168.10.75";
      Port = 2222;
      User = owner.name;
      IdentityFile = "~/.ssh/id_ed25519_agent_workstation_worker";
      IdentitiesOnly = true;
      ForwardAgent = false;
      StrictHostKeyChecking = "yes";
      HostKeyAlias = "workstation-worker";
      UserKnownHostsFile = "/etc/ssh/ssh_known_hosts";
    };
  };
}
