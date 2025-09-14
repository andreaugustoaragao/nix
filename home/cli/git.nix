{
  config,
  pkgs,
  lib,
  inputs,
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
      commit.gpgsign = true;
      tag.gpgsign = true;
      # Automatically select GPG key based on email address
      gpg.program = "${pkgs.gnupg}/bin/gpg";
      # Use default key selection based on email
      user.signingkey = "";
    };

    # Conditional includes for different directories
    includes = [
      {
        condition = "gitdir:/home/aragao/projects/personal/";
        contents = {
          user = {
            name = "andreaugustoaragao";
            email = "andrearag@gmail.com";
            # GPG key will be automatically selected based on email
          };
        };
      }
      {
        condition = "gitdir:/home/aragao/projects/work/";
        contents = {
          user = {
            name = "andrearagao";
            email = "aragao@avaya.com";
            # GPG key will be automatically selected based on email
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

