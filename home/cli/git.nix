{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Signing on Darwin uses SSH via ssh-agent (loaded at login by
  # home/cli/ssh-agent-macos.nix). On Linux signing uses GPG via the
  # sops-managed secret keys imported by home/cli/gpg.nix. Same identity
  # split (personal vs work via gitdir includeIf), different transport.
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  homeDir = config.home.homeDirectory;

  personalSigningKey = if isDarwin then "${homeDir}/.ssh/id_rsa_personal.pub" else "E42EDF7958831F08";
  workSigningKey = if isDarwin then "${homeDir}/.ssh/id_rsa_work.pub" else "D8BAA25EFB1D5C5F";

  # Allowed-signers file lets `git log --show-signature` verify SSH
  # signatures locally. Generated at activation from the actual deployed
  # public keys so it tracks any sops-managed key rotation. GitHub does
  # its own verification against keys added at
  # https://github.com/settings/ssh/new (with Type = "Signing Key").
  allowedSignersFile = "${homeDir}/.config/git/allowed_signers";
in
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
        commit.gpgsign = true;
        tag.gpgsign = true;

        # Sign transport: GPG on Linux, SSH on Darwin. Set `gpg.format`
        # = ssh and git uses the ssh-keygen binary to sign with whatever
        # key matches the path in `user.signingkey`, asking ssh-agent
        # for the private half — no GPG dependency on macOS at all.
        gpg =
          if isDarwin then
            {
              format = "ssh";
              ssh.allowedSignersFile = allowedSignersFile;
            }
          else
            {
              program = "${pkgs.gnupg}/bin/gpg";
            };

        # Let gh broker HTTPS credentials for github.com so we never
        # need a stored PAT or `git config --global credential.helper`
        # (the latter fails on Home Manager since ~/.config/git/config
        # is a /nix/store symlink). After `gh auth login --with-token`
        # this kicks in automatically for push/fetch over HTTPS.
        credential."https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
        credential."https://gist.github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";

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

      # Conditional includes for different directories. Path is taken
      # from config.home.homeDirectory so the same module works on
      # Linux (/home/aragao) and Darwin (/Users/aragao). The signing
      # key value differs by platform — see the let block above.
      includes = [
        {
          condition = "gitdir:${homeDir}/projects/personal/";
          contents.user = {
            name = "andreaugustoaragao";
            email = "andrearag@gmail.com";
            signingkey = personalSigningKey;
          };
        }
        {
          condition = "gitdir:${homeDir}/projects/work/";
          contents.user = {
            name = "andrearagao";
            email = "aragao@avaya.com";
            signingkey = workSigningKey;
          };
        }
      ];
    };
  };

  # Materialize ~/.config/git/allowed_signers from the sops-decrypted
  # public keys. Only meaningful on Darwin (Linux signs via GPG); on
  # Linux the activation is a no-op via lib.mkIf.
  home.activation.gitAllowedSigners = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -eu
      $DRY_RUN_CMD mkdir -p ${homeDir}/.config/git
      tmp="${allowedSignersFile}.tmp"
      : >"$tmp"
      if [ -r ${homeDir}/.ssh/id_rsa_personal.pub ]; then
        printf 'andrearag@gmail.com %s\n' \
          "$(cat ${homeDir}/.ssh/id_rsa_personal.pub)" >>"$tmp"
      fi
      if [ -r ${homeDir}/.ssh/id_rsa_work.pub ]; then
        printf 'aragao@avaya.com %s\n' \
          "$(cat ${homeDir}/.ssh/id_rsa_work.pub)" >>"$tmp"
      fi
      $DRY_RUN_CMD mv "$tmp" "${allowedSignersFile}"
    ''
  );
}
