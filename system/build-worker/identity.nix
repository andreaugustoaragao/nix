{
  config,
  lib,
  pkgs,
  owner,
  ...
}:
let
  identity = "/home/.worker-identity";
  encrypted = ../../secrets/workers + "/workstation-worker.yaml";
  ready = builtins.pathExists encrypted;
  credentialNames = builtins.fromJSON (builtins.readFile ../../secrets/workers/credential-names.json);
  sshPaths = {
    ssh_key_github_personal = "/home/${owner.name}/.ssh/id_rsa_personal";
    ssh_key_github_work = "/home/${owner.name}/.ssh/id_rsa_work";
    ssh_pubkey_github_personal = "/home/${owner.name}/.ssh/id_rsa_personal.pub";
    ssh_pubkey_github_work = "/home/${owner.name}/.ssh/id_rsa_work.pub";
  };
in
{
  sops = {
    useSystemdActivation = true;
    age = {
      keyFile = "${identity}/age.txt";
      generateKey = false;
      sshKeyPaths = [ ];
    };
    gnupg.sshKeyPaths = [ ];
    secrets = lib.optionalAttrs ready (
      lib.genAttrs credentialNames (
        name:
        {
          sopsFile = encrypted;
          owner = owner.name;
          mode = "0400";
        }
        // lib.optionalAttrs (builtins.hasAttr name sshPaths) { path = sshPaths.${name}; }
        // lib.optionalAttrs (lib.hasPrefix "ssh_" name) {
          restartUnits = [ "worker-git-refresh.service" ];
        }
        //
          lib.optionalAttrs
            (builtins.elem name [
              "gpg_key_personal"
              "gpg_key_work"
            ])
            {
              restartUnits = [ "home-manager-${owner.name}.service" ];
            }
      )
    );
  };
  systemd.services.worker-identity = {
    wantedBy = [ "multi-user.target" ];
    before = [
      "nix-daemon.service"
      "sshd-keygen.service"
      "sops-install-secrets.service"
      "user@1000.service"
      "home-manager-${owner.name}.service"
    ];
    unitConfig.RequiresMountsFor = [ "/home" ];
    unitConfig.DefaultDependencies = false;
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    path = [
      pkgs.coreutils
      pkgs.openssh
      pkgs.age
      pkgs.openssl
      pkgs.jq
    ];
    script = ''
      set -eu
      install -d -m 0700 -o ${owner.name} -g users /home/${owner.name}
      install -d -m 0700 ${identity}
      if [ ! -s ${identity}/cache.sec ]; then
        ${config.nix.package}/bin/nix key generate-secret --key-name workstation-worker-1 > ${identity}/cache.sec.new
        mv ${identity}/cache.sec.new ${identity}/cache.sec
      fi
      if [ ! -s ${identity}/age.txt ]; then
        age-keygen -o ${identity}/age.txt.new
        mv ${identity}/age.txt.new ${identity}/age.txt
      fi
      if [ ! -s ${identity}/ssh_host_ed25519_key ]; then
        ssh-keygen -q -t ed25519 -N "" -f ${identity}/ssh_host_ed25519_key
      fi
      if [ ! -s ${identity}/keyring-password ]; then
        openssl rand -hex 32 > ${identity}/keyring-password.new
        mv ${identity}/keyring-password.new ${identity}/keyring-password
      fi
      install -d /etc/workstation-worker /etc/nix
      ${config.nix.package}/bin/nix key convert-secret-to-public < ${identity}/cache.sec > /etc/nix/worker-cache.pub
      age-keygen -y ${identity}/age.txt > /etc/workstation-worker/age.pub
      jq -n --arg ssh "$(cat ${identity}/ssh_host_ed25519_key.pub)" \
        --arg cache "$(cat /etc/nix/worker-cache.pub)" \
        --arg age "$(cat /etc/workstation-worker/age.pub)" \
        '{ssh:$ssh,cache:$cache,age:$age}' > /etc/workstation-worker/public-identities.json
      chmod 0644 /etc/nix/worker-cache.pub /etc/workstation-worker/{age.pub,public-identities.json}
    '';
  };
  systemd.services.worker-git-prepare = lib.mkIf ready {
    description = "Prepare private worker SSH paths before decryption";
    requires = [ "worker-identity.service" ];
    after = [
      "worker-identity.service"
      "local-fs.target"
    ];
    before = [ "sops-install-secrets.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      ExecStart = "${pkgs.python3}/bin/python3 ${../../home/cli/worker-git-credentials.py} prepare --home /home/${owner.name} --uid ${
        toString config.users.users.${owner.name}.uid
      } --gid ${toString config.users.groups.users.gid}";
    };
  };
  systemd.services.sops-install-secrets = lib.mkIf ready {
    requires = [
      "worker-identity.service"
      "worker-git-prepare.service"
    ];
    after = [
      "worker-identity.service"
      "worker-git-prepare.service"
    ];
  };
  systemd.services.worker-git-refresh = lib.mkIf ready {
    description = "Refresh only managed worker Git identities after secret changes";
    wantedBy = [ "multi-user.target" ];
    requires = [ "user@1000.service" ];
    after = [
      "sops-install-secrets.service"
      "home-manager-${owner.name}.service"
      "user@1000.service"
    ];
    environment = {
      XDG_RUNTIME_DIR = "/run/user/1000";
      DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
    };
    serviceConfig = {
      User = owner.name;
      Group = "users";
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      worker_git_load_state="$(${pkgs.systemd}/bin/systemctl --user show worker-git-ssh-keys.service --property=LoadState --value)"
      case "$worker_git_load_state" in
        loaded) exec ${pkgs.systemd}/bin/systemctl --user restart worker-git-ssh-keys.service ;;
        not-found) : ;;
        *) echo 'Worker Git key loader is unavailable.' >&2; exit 1 ;;
      esac
    '';
  };
  assertions = [
    {
      assertion = !ready || config.sops.useSystemdActivation;
      message = "Worker credentials require systemd activation after the persistent identity is ready.";
    }
  ];
  services.gnome.gnome-keyring.enable = true;
  systemd.services.worker-keyring = {
    wantedBy = [ "multi-user.target" ];
    requires = [
      "worker-identity.service"
      "user@1000.service"
    ];
    after = [
      "worker-identity.service"
      "user@1000.service"
    ];
    environment = {
      HOME = "/home/${owner.name}";
      XDG_RUNTIME_DIR = "/run/user/1000";
      DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
    };
    serviceConfig = {
      User = owner.name;
      Type = "simple";
      UMask = "0077";
      LoadCredential = "password:${identity}/keyring-password";
      Restart = "on-failure";
      RestartSec = 3;
      ExecStart = pkgs.writeShellScript "worker-keyring" ''
        exec /run/wrappers/bin/gnome-keyring-daemon --foreground --components=secrets --unlock < "$CREDENTIALS_DIRECTORY/password"
      '';
    };
  };
  systemd.services."home-manager-${owner.name}" = {
    requires = [
      "worker-identity.service"
      "sops-install-secrets.service"
    ];
    after = [
      "worker-identity.service"
      "sops-install-secrets.service"
    ];
  };
  systemd.services."user@1000" = {
    overrideStrategy = "asDropin";
    requires = [ "worker-identity.service" ];
    after = [ "worker-identity.service" ];
    serviceConfig = {
      CPUQuota = "1800%";
      MemoryHigh = "40G";
      MemoryMax = "48G";
      TasksMax = 16384;
    };
  };
  services.qemuGuest.enable = true;
}
