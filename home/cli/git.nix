{
  pkgs,
  owner,
  ...
}:

{
  programs = {
    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        dark = true;
        line-numbers = true;
        navigate = true;
        side-by-side = true;
        syntax-theme = "base16";

        file-style = "bold #cba6f7";
        hunk-header-file-style = "bold #89b4fa";
        hunk-header-line-number-style = "#f9e2af";
        line-numbers-left-style = "#6c7086";
        line-numbers-right-style = "#6c7086";
        line-numbers-minus-style = "#f38ba8";
        line-numbers-plus-style = "#a6e3a1";
        minus-emph-style = "syntax #45475a";
        minus-style = "syntax #313244";
        plus-emph-style = "syntax #45475a";
        plus-style = "syntax #313244";
      };
    };

    git = {
      enable = true;

      settings = {
        user = {
          name = "andrearagao";
          email = "aragao@avaya.com"; # Default to work email
        };

        init.defaultBranch = "main";
        pull.rebase = false;
        push.autoSetupRemote = true;
        # Re-enable GPG signing with proper keys configured
        commit.gpgsign = true;
        tag.gpgsign = true;
        # GPG program path
        gpg.program = "${pkgs.gnupg}/bin/gpg";

        alias = {
          st = "status";
          co = "checkout";
          br = "branch";
          ci = "commit";
          unstage = "reset HEAD --";
          last = "log -1 HEAD";
          visual = "!gitk";
        };
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
    };
  };
}
