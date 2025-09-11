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
      # GPG program will be set automatically by programs.gpg
    };

    # Conditional includes for different directories
    includes = [
      {
        condition = "gitdir:/home/aragao/projects/personal/";
        contents = {
          user = {
            name = "andreaugustoaragao";
            email = "andrearag@gmail.com";
            signingkey = "74CCE1A4F133BE6F";
          };
        };
      }
      {
        condition = "gitdir:/home/aragao/projects/work/";
        contents = {
          user = {
            name = "andrearagao";
            email = "aragao@avaya.com";
            signingkey = "792E9235301AC862";
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

