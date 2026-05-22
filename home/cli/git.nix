{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Path the work-scope `includeIf` points at. Written by the
  # `gitWorkInclude` home.activation below from the sops-managed
  # email at /run/secrets/git_email_work. We deliberately do NOT use
  # `programs.git.includes[].contents` for the work scope (it would
  # bake the email into the Nix store — the exact leak this commit
  # is fixing).
  workConfigPath = "${config.home.homeDirectory}/.config/git/work.gitconfig";
  workEmailSecret = "/run/secrets/git_email_work";
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
        # Personal identity as the top-level default. Per-scope
        # `includeIf` blocks below override for projects/personal/
        # and projects/work/. The top-level default only fires for
        # repos outside both — better to leak personal than work.
        user = {
          name = "andreaugustoaragao";
          email = "andrearag@gmail.com";
        };

        init.defaultBranch = "main";
        pull.rebase = false;
        push.autoSetupRemote = true;
        # Re-enable GPG signing with proper keys configured
        commit.gpgsign = true;
        tag.gpgsign = true;
        # GPG program path
        gpg.program = "${pkgs.gnupg}/bin/gpg";

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
      # Linux (/home/aragao) and Darwin (/Users/aragao).
      includes = [
        {
          condition = "gitdir:${config.home.homeDirectory}/projects/personal/";
          contents = {
            user = {
              name = "andreaugustoaragao";
              email = "andrearag@gmail.com";
              signingkey = "E42EDF7958831F08";
            };
          };
        }
        # Work scope: point at a file written by the activation
        # script below (NOT a `contents = { ... }` inline block).
        # That's what keeps the work email out of /nix/store. Git
        # silently ignores a missing path, so unprovisioned hosts
        # just fall back to the top-level personal default for work
        # repos — which is fine; you'll notice the wrong author on
        # the next commit.
        {
          condition = "gitdir:${config.home.homeDirectory}/projects/work/";
          path = workConfigPath;
        }
      ];
    };
  };

  # Render ~/.config/git/work.gitconfig from the sops-managed work
  # email. The signing key ID is a public hex blob (not
  # employer-revealing) so it stays inlined. The name is constant.
  # Only the email comes from sops.
  home.activation.gitWorkInclude = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="${workConfigPath}"
    mkdir -p "$(dirname "$target")"

    if [[ -f "${workEmailSecret}" ]]; then
      email="$(cat "${workEmailSecret}")"
      if [[ -n "$email" && "$email" != "placeholder" ]]; then
        cat > "$target.tmp" <<EOF
    [user]
    	name = andrearagao
    	email = $email
    	signingkey = D8BAA25EFB1D5C5F
    EOF
        mv "$target.tmp" "$target"
        chmod 0600 "$target"
      else
        # Secret present but empty / placeholder — wipe any stale
        # rendering rather than leave a half-baked file in place.
        rm -f "$target"
      fi
    else
      # Sops hasn't deployed the secret yet (first install, age key
      # not provisioned, etc.). Leave no work.gitconfig at all so
      # the includeIf is a clean no-op.
      rm -f "$target"
    fi
  '';
}
