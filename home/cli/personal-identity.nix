{ config, pkgs, ... }:

{
  # Fresh keys are enrolled interactively after installation. No existing
  # fleet identities, passphrases, work accounts, or agent sockets are imported.
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        ForwardAgent = false;
        IdentitiesOnly = true;
      };
      "github.com github-personal" = {
        HostName = "ssh.github.com";
        Port = 443;
        HostKeyAlias = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_ed25519_personal";
      };
    };
  };
  services.ssh-agent.enable = true;
  programs.gpg.enable = true;
  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.pinentry-qt;
    enableSshSupport = false;
  };
  programs.git.settings = {
    gpg.format = "ssh";
    user.signingkey = "${config.home.homeDirectory}/.ssh/id_ed25519_personal.pub";
  };
}
