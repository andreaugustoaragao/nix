_:

# Cross-platform SSH client config — same shape on Linux and macOS.
#
# Owns just `programs.ssh.*`, no agent/askpass wiring. Those pieces are
# platform-specific:
#   - Linux: see home/cli/gpg.nix (systemd-user ssh-agent + kdePackages.ksshaskpass)
#   - macOS: launchd-managed ssh-agent + Keychain (TODO: wire up Phase B)
#
# The github-personal / github-work aliases point at sops-decrypted keys
# under ~/.ssh/, materialized by sops-nix on both platforms.
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
      # `prl-dev-vm.local` from the VM (see system/mdns.nix). Agent
      # forwarding is on globally via extraConfig above.
      "prl-dev-vm" = {
        hostname = "prl-dev-vm.local";
        user = "aragao";
      };

      # VMware Fusion sibling of prl-dev-vm — same flake profile, just a
      # different hypervisor under mac-work. mDNS publishing is enabled
      # the same way (system/mdns.nix), so we don't need to track the
      # VMware NAT lease either.
      "vmw-dev-vm" = {
        hostname = "vmw-dev-vm.local";
        user = "aragao";
      };
    };
  };
}
