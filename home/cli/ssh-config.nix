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
    };
  };
}
