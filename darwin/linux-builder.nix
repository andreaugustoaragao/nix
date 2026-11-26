{
  config,
  lib,
  ...
}:

# Hardened aarch64-linux remote Nix builder client on mac-work -> prl-dev-vm.
#
# Mirrors system/workstation-build-client.nix:
#   - Dedicated daemon-owned SSH key (`/etc/nix/prl-builder-ssh`, 0400 root)
#     and Nix store signing key (`/etc/nix/prl-builder-cache.sec`, 0400 root),
#     separate from the interactive user's `~/.ssh/id_ed25519_peers`.
#   - Connects over the Parallels host-only bridge (`10.211.55.4`) to
#     `prl-dev-vm`'s untrusted `nix-ssh` endpoint with strict host-key pinning
#     (`secrets/ssh_host_keys/prl-dev-vm.pub`).
#   - Trusts `prl-dev-vm`'s existing store signing key
#     (`secrets/workers/clients/cache-prl-dev-vm.pub`).
#
# First activation generates `/etc/nix/prl-builder-{ssh,cache}.pub` if absent.
# Distributed builds activate automatically once those two public keys are
# committed under `secrets/prl-builder/`.

let
  hostKey = ../secrets/ssh_host_keys/prl-dev-vm.pub;
  serverCachePub = ../secrets/workers/clients/cache-prl-dev-vm.pub;
  clientSshPub = ../secrets/prl-builder/mac-work-ssh.pub;
  clientCachePub = ../secrets/prl-builder/mac-work-cache.pub;

  ready =
    builtins.pathExists hostKey
    && builtins.pathExists serverCachePub
    && builtins.pathExists clientSshPub
    && builtins.pathExists clientCachePub;
in
{
  config = lib.mkMerge [
    {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        (
          umask 077
          /bin/mkdir -p /etc/nix
          tmp_dir=$(/usr/bin/mktemp -d /etc/nix/.prl-builder-keygen.XXXXXX)
          trap '/bin/rm -rf "$tmp_dir"' EXIT
          /usr/sbin/chown root:wheel "$tmp_dir"
          /bin/chmod 0700 "$tmp_dir"

          if [ ! -s /etc/nix/prl-builder-ssh ]; then
            /usr/bin/ssh-keygen -q -t ed25519 -N "" -C "nix-daemon@mac-work" -f "$tmp_dir/ssh"
            /usr/sbin/chown root:wheel "$tmp_dir/ssh" "$tmp_dir/ssh.pub"
            /bin/chmod 0400 "$tmp_dir/ssh"
            /bin/chmod 0644 "$tmp_dir/ssh.pub"
            /bin/mv -f "$tmp_dir/ssh" /etc/nix/prl-builder-ssh
            /bin/mv -f "$tmp_dir/ssh.pub" /etc/nix/prl-builder-ssh.pub
          fi
          if [ ! -s /etc/nix/prl-builder-cache.sec ] \
            || ! /usr/bin/grep -q '^mac-work-builder-2:' /etc/nix/prl-builder-cache.pub 2>/dev/null; then
            ${config.nix.package}/bin/nix key generate-secret --key-name mac-work-builder-2 > "$tmp_dir/cache.sec"
            ${config.nix.package}/bin/nix key convert-secret-to-public < "$tmp_dir/cache.sec" > "$tmp_dir/cache.pub"
            /usr/sbin/chown root:wheel "$tmp_dir/cache.sec" "$tmp_dir/cache.pub"
            /bin/chmod 0400 "$tmp_dir/cache.sec"
            /bin/chmod 0644 "$tmp_dir/cache.pub"
            /bin/mv -f "$tmp_dir/cache.sec" /etc/nix/prl-builder-cache.sec
            /bin/mv -f "$tmp_dir/cache.pub" /etc/nix/prl-builder-cache.pub
          fi
        )
      '';
    }

    (lib.mkIf ready {
      nix = {
        distributedBuilds = true;
        buildMachines = [
          {
            hostName = "prl-dev-vm-builder";
            protocol = "ssh-ng";
            sshUser = "nix-ssh";
            sshKey = "/etc/nix/prl-builder-ssh";
            systems = [ "aarch64-linux" ];
            maxJobs = 2;
            speedFactor = 2;
            supportedFeatures = [ "big-parallel" ];
          }
        ];
        settings = {
          builders-use-substitutes = true;
          secret-key-files = [ "/etc/nix/prl-builder-cache.sec" ];
          trusted-public-keys = [ (lib.trim (lib.fileContents serverCachePub)) ];
        };
      };

      # System-wide SSH config for nix-daemon (runs as root via Apple /usr/bin/ssh,
      # whose /etc/ssh/ssh_config includes /etc/ssh/ssh_config.d/*).
      environment.etc = {
        "ssh/prl_builder_known_hosts".text = ''
          prl-dev-vm.local ${lib.trim (lib.fileContents hostKey)}
        '';
        "ssh/ssh_config.d/200-prl-builder.conf".text = ''
          Host prl-dev-vm-builder
            HostName 10.211.55.4
            User nix-ssh
            HostKeyAlias prl-dev-vm.local
            IdentityFile /etc/nix/prl-builder-ssh
            IdentitiesOnly yes
            StrictHostKeyChecking yes
            UserKnownHostsFile /etc/ssh/prl_builder_known_hosts
        '';
      };
    })
  ];
}
