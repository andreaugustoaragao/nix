{
  config,
  pkgs,
  lib,
  inputs,
  owner,
  ...
}:

{
  programs.git = {
    enable = true;
    userName = "andrearagao";
    userEmail = "aragao@avaya.com"; # Default to work email

    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = false;
      push.autoSetupRemote = true;
      # Re-enable GPG signing with proper keys configured
      commit.gpgsign = true;
      tag.gpgsign = true;
      # GPG program path
      gpg.program = "${pkgs.gnupg}/bin/gpg";
    };

    # Conditional includes for different directories
    includes = [
      {
        condition = "gitdir:/home/${owner.name}/projects/personal/";
        contents = {
          user = {
            name = "andreaugustoaragao";
            email = "andrearag@gmail.com";
            signingkey = "E42EDF7958831F08";
          };
        };
      }
      {
        condition = "gitdir:/home/${owner.name}/projects/work/";
        contents = {
          user = {
            name = "andrearagao";
            email = "aragao@avaya.com";
            signingkey = "D8BAA25EFB1D5C5F";
          };
        };
      }
    ];

    aliases = {
      st = "status";
      co = "checkout";
      br = "branch";
      ci = "commit";
      unstage = "reset HEAD --";
      last = "log -1 HEAD";
      visual = "!gitk";
    };
  };
}

