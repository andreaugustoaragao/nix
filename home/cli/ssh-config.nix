{ lib, ... }:

# Cross-platform SSH client config — same shape on Linux and macOS.
#
# Owns just `programs.ssh.*`, no agent/askpass wiring. Those pieces are
# platform-specific:
#   - Linux: see home/cli/gpg.nix (systemd-user ssh-agent + kdePackages.ksshaskpass)
#   - macOS: launchd-managed ssh-agent (see home/cli/ssh-agent-macos.nix)
#
# Identity files:
#   - github-{personal,work}: sops-decrypted GitHub keys (per identity)
#   - id_ed25519_fleet: locally-generated fleet key (per host, via
#     `nix run .#fleet-bootstrap`). Never enters sops; lives only on
#     the host that generated it.

let
  # Host pubkeys for fleet peers live under secrets/ssh_host_keys/*.pub
  # (plaintext — host pubkeys aren't secrets). Format inside each file
  # is just the key portion, e.g.
  #   ssh-ed25519 AAAA... root@prl-dev-vm
  # `nix run .#fleet-bootstrap` writes these via ssh-keyscan.
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
in
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    extraConfig = ''
      # Forward the local agent so remote shells can SSH onward (used
      # for chained jumps; harmless when there's no agent running).
      ForwardAgent yes
    '';

    matchBlocks = {
      "*" = {
        addKeysToAgent = "yes";
        compression = true;
        serverAliveInterval = 60;
        serverAliveCountMax = 3;
      };

      "github-personal" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_rsa_personal"; # From sops
        identitiesOnly = true;
      };

      "github-work" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_rsa_work"; # From sops
        identitiesOnly = true;
      };

      # Parallels dev VM. Reached over the Parallels Shared Network at
      # whatever DHCP/static IP it ends up with — resolved via Bonjour
      # so we don't have to track the address. avahi-daemon publishes
      # `prl-dev-vm.local` from the VM (see system/mdns.nix).
      #
      # StrictHostKeyChecking is hard-on, with the known_hosts file
      # written declaratively from secrets/ssh_host_keys/. No TOFU.
      "prl-dev-vm" = {
        hostname = "prl-dev-vm.local";
        user = "aragao";
        identityFile = "~/.ssh/id_ed25519_fleet";
        identitiesOnly = true;
        extraOptions = {
          StrictHostKeyChecking = "yes";
          UserKnownHostsFile = "~/.ssh/known_hosts_fleet";
        };
      };

      # VMware Fusion sibling of prl-dev-vm — same flake profile, just a
      # different hypervisor under mac-work. mDNS publishing is enabled
      # the same way (system/mdns.nix). Same fleet-key treatment once
      # bootstrap runs on the VMware VM (or pubkey lands via another
      # client's bootstrap), and a hostkey is ssh-keyscanned in.
      "vmw-dev-vm" = {
        hostname = "vmw-dev-vm.local";
        user = "aragao";
        identityFile = "~/.ssh/id_ed25519_fleet";
        identitiesOnly = true;
        extraOptions = {
          StrictHostKeyChecking = "yes";
          UserKnownHostsFile = "~/.ssh/known_hosts_fleet";
        };
      };
    };
  };

  # Declarative known_hosts file for fleet peers. Separate from the
  # default ~/.ssh/known_hosts so interactive ssh additions to ad-hoc
  # hosts (e.g. via accept-new) don't get clobbered on rebuild.
  home.file.".ssh/known_hosts_fleet".text = knownHostsText;
}
