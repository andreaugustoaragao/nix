{
  config,
  lib,
  pkgs,
  kubernetesVmAddress,
  ...
}:

# Cross-platform SSH client config — same shape on Linux and macOS.
#
# Owns just `programs.ssh.*`, no agent/askpass wiring. Those pieces are
# platform-specific:
#   - Linux: see home/cli/gpg.nix (systemd-user ssh-agent + kdePackages.ksshaskpass)
#   - macOS: launchd-managed ssh-agent (see home/cli/ssh-agent-macos.nix)
#
# Identity files:
#   - github-{personal,work}: sops-decrypted GitHub keys (per identity)
#   - id_ed25519_peers: locally-generated per-host key (one per peer,
#     via `nix run .#peers-bootstrap`). Never enters sops; lives only
#     on the host that generated it.

let
  # Host pubkeys for peers live under secrets/ssh_host_keys/*.pub
  # (plaintext — host pubkeys aren't secrets). Format inside each file
  # is just the key portion, e.g.
  #   ssh-ed25519 AAAA... root@prl-dev-vm
  # `nix run .#peers-bootstrap` writes these via ssh-keyscan.
  hostKeysDir = ../../secrets/ssh_host_keys;

  knownHostsText =
    let
      files = builtins.filter (lib.hasSuffix ".pub") (lib.attrNames (builtins.readDir hostKeysDir));
      formatEntry =
        f:
        let
          host = lib.removeSuffix ".pub" f;
          key = lib.fileContents "${hostKeysDir}/${f}";
        in
        "${host},${host}.local ${key}";
    in
    lib.concatStringsSep "\n" (map formatEntry files) + "\n";

  sshConfigCheck = ''
    ssh_dir="${config.home.homeDirectory}/.ssh"
    ssh_config="$ssh_dir/config"
    stamp="$ssh_dir/.config.hm-sha256"
    src="${config.home.file.".ssh/config".source}"

    if [[ -d "$ssh_config" && ! -L "$ssh_config" ]]; then
      echo "materializeSshConfig: refusing to overwrite directory $ssh_config" >&2
      exit 1
    fi

    if [[ -L "$ssh_config" ]]; then
      target="$(${pkgs.coreutils}/bin/readlink "$ssh_config")"
      case "$target" in
        /nix/store/*-home-manager-files/.ssh/config) ;;
        *)
          echo "materializeSshConfig: refusing to overwrite unmanaged symlink $ssh_config -> $target" >&2
          exit 1
          ;;
      esac
    elif [[ -e "$ssh_config" ]]; then
      if [[ ! -f "$ssh_config" ]]; then
        echo "materializeSshConfig: refusing to overwrite non-regular file $ssh_config" >&2
        exit 1
      fi
      if ! ${pkgs.diffutils}/bin/cmp -s "$src" "$ssh_config"; then
        cur_hash="$(${pkgs.coreutils}/bin/sha256sum "$ssh_config" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
        prev_hash=""
        if [[ -f "$stamp" ]]; then
          prev_hash="$(${pkgs.coreutils}/bin/cat "$stamp")"
        fi
        if [[ -z "$prev_hash" || "$cur_hash" != "$prev_hash" ]]; then
          echo "materializeSshConfig: refusing to overwrite unmanaged or locally edited $ssh_config" >&2
          exit 1
        fi
      fi
    fi
  '';
in
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    # ForwardAgent is intentionally NOT enabled globally: the agent holds
    # non-expiring personal + work GitHub keys, and forwarding it to every
    # destination lets any root on a remote host authenticate as us. There
    # are no jump hosts today; if one appears, set `forwardAgent = true` on
    # that matchBlock only (and prefer ProxyJump).

    # 26.05 deprecated `matchBlocks` (HM-cased keys + extraOptions) in favor
    # of `settings`, a freeform attrset keyed by upstream OpenSSH directive
    # names written verbatim into ~/.ssh/config.
    settings = {
      "*" = {
        AddKeysToAgent = "yes";
        Compression = true;
        ServerAliveInterval = 60;
        ServerAliveCountMax = 3;
      };

      # GitHub over 443 rather than 22. GitHub serves the same SSH endpoint
      # on ssh.github.com:443 precisely for networks that block or intercept
      # port 22, and at least one network this fleet sits behind terminates
      # every outbound :22 connection on a middlebox that presents its own
      # host keys. HostKeyAlias pins the session to the `github.com` entries
      # already in known_hosts, so the real GitHub keys still gate the
      # connection — this routes around the interception without weakening
      # verification. Harmless on clean networks; 443 is a first-class
      # GitHub endpoint, not a fallback.
      "github-personal" = {
        HostName = "ssh.github.com";
        Port = 443;
        HostKeyAlias = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_rsa_personal"; # From sops
        IdentitiesOnly = true;
      };

      "github-work" = {
        HostName = "ssh.github.com";
        Port = 443;
        HostKeyAlias = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_rsa_work"; # From sops
        IdentitiesOnly = true;
      };

      # Bare `git@github.com:...` remotes (this flake's own origin, among
      # others) don't match the aliases above, so they need the same
      # treatment or they go out on :22.
      "github.com" = {
        HostName = "ssh.github.com";
        Port = 443;
        HostKeyAlias = "github.com";
        User = "git";
      };

      # Parallels dev VM. Reached over the Parallels Shared Network at
      # whatever DHCP/static IP it ends up with — resolved via Bonjour
      # so we don't have to track the address. avahi-daemon publishes
      # `prl-dev-vm.local` from the VM (see system/mdns.nix).
      #
      # StrictHostKeyChecking is hard-on, with the known_hosts file
      # written declaratively from secrets/ssh_host_keys/. No TOFU.
      "prl-dev-vm" = {
        HostName = "prl-dev-vm.local";
        User = "aragao";
        IdentityFile = "~/.ssh/id_ed25519_peers";
        IdentitiesOnly = true;
        StrictHostKeyChecking = "yes";
        UserKnownHostsFile = "~/.ssh/known_hosts_peers";
      };

      # Dedicated cluster: bootstrap its host key against the VM console.
      # Its own known_hosts file allows installation before a desktop rebuild.
      "prl-k8s-vm" = {
        HostName = kubernetesVmAddress;
        HostKeyAlias = "prl-k8s-vm";
        User = "aragao";
        IdentityFile = [
          "~/.ssh/id_ed25519_peers"
          "~/.ssh/id_rsa_personal"
        ];
        IdentitiesOnly = true;
        ForwardAgent = false;
        StrictHostKeyChecking = "yes";
        UserKnownHostsFile = "~/.ssh/known_hosts_k8s";
      };

      # VMware Fusion sibling of prl-dev-vm — same flake profile, just a
      # different hypervisor under mac-work. mDNS publishing is enabled
      # the same way (system/mdns.nix). Same peer-key treatment once
      # bootstrap runs on the VMware VM (or pubkey lands via another
      # client's bootstrap), and a hostkey is ssh-keyscanned in.
      "vmw-dev-vm" = {
        HostName = "vmw-dev-vm.local";
        User = "aragao";
        IdentityFile = "~/.ssh/id_ed25519_peers";
        IdentitiesOnly = true;
        StrictHostKeyChecking = "yes";
        UserKnownHostsFile = "~/.ssh/known_hosts_peers";
      };
    };
  };

  # Materialize ~/.ssh/config as a user-owned 0600 regular file rather than a
  # symlink to root-owned /nix/store. Inside user-namespaced sandboxes where
  # UID 0 is unmapped (e.g. bwrap/OMP), root-owned store targets appear as
  # nobody (65534) and OpenSSH rejects ~/.ssh/config with "Bad owner or permissions".
  home.file.".ssh/config".enable = lib.mkForce false;

  # Read-only preflight before writeBoundary so a locally edited ~/.ssh/config
  # aborts activation before Home Manager mutates any other file.
  home.activation.checkSshConfigCollision = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    (
      ${sshConfigCheck}
    )
  '';

  home.activation.materializeSshConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [[ -z "''${DRY_RUN:-}" ]]; then
      (
        umask 077
        ${sshConfigCheck}
        mkdir -p "$ssh_dir"
        chmod 0700 "$ssh_dir"
        tmp="$(${pkgs.coreutils}/bin/mktemp "$ssh_dir/.config.XXXXXX")"
        stamp_tmp="$(${pkgs.coreutils}/bin/mktemp "$ssh_dir/.config.hm-sha256.XXXXXX")"
        trap 'rm -f "$tmp" "$stamp_tmp"' EXIT
        ${pkgs.coreutils}/bin/cp "$src" "$tmp"
        ${pkgs.coreutils}/bin/chmod 0600 "$tmp"
        ${pkgs.coreutils}/bin/sha256sum "$tmp" | ${pkgs.coreutils}/bin/cut -d' ' -f1 > "$stamp_tmp"
        ${pkgs.coreutils}/bin/chmod 0600 "$stamp_tmp"
        ${pkgs.coreutils}/bin/mv -fT "$tmp" "$ssh_config"
        ${pkgs.coreutils}/bin/mv -fT "$stamp_tmp" "$stamp"
        trap - EXIT
      )
    fi
  '';

  # Declarative known_hosts file for peers. Separate from the default
  # ~/.ssh/known_hosts so interactive ssh additions to ad-hoc hosts
  # (e.g. via accept-new) don't get clobbered on rebuild.
  home.file.".ssh/known_hosts_peers".text = knownHostsText;
}
