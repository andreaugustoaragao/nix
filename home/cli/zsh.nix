{ pkgs, lib, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
{
  # Shell configuration
  programs.zsh = {
    enable = true;

    # On Darwin, Homebrew installs to /opt/homebrew (Apple Silicon) and
    # exposes its tools via `brew shellenv`. This is the declarative
    # replacement for the imperative two-line block brew prints at the
    # end of its installer:
    #
    #   echo 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"' >> ~/.zprofile
    #
    # profileExtra is written to ~/.zprofile by home-manager.
    profileExtra = lib.mkIf isDarwin ''
      eval "$(/opt/homebrew/bin/brew shellenv zsh)"
    '';
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting = {
      enable = true;
      styles = {
        alias = "fg=#89b4fa";
        builtin = "fg=#89b4fa";
        command = "fg=#89b4fa";
        comment = "fg=#6c7086";
        function = "fg=#89b4fa";
        path = "fg=#a6e3a1,underline";
        precommand = "fg=#cba6f7";
        single-hyphen-option = "fg=#f9e2af";
        double-hyphen-option = "fg=#f9e2af";
        single-quoted-argument = "fg=#a6e3a1";
        double-quoted-argument = "fg=#a6e3a1";
        unknown-token = "fg=#f38ba8";
      };
    };

    shellAliases = {
      # File listing
      ls = "eza -lh --group-directories-first --icons=auto";
      lsa = "eza -lh --group-directories-first --icons=auto -a";
      lt = "eza --tree --level=2 --long --icons --git";
      lta = "eza --tree --level=2 --long --icons --git -a";
      ll = "ls -alF";
      la = "ls -A";
      l = "ls -CF";

      # System management
      rebuild = "sudo nixos-rebuild switch --flake .";
      update = "nix flake update";

      # Editor shortcuts
      v = "nvim";
      vim = "nvim";
      vi = "nvim";

      # Git shortcuts
      g = "git";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcm = "git commit -m";
      gca = "git commit --amend";
      gco = "git checkout";
      gcb = "git checkout -b";
      gd = "git diff";
      gds = "git diff --staged";
      gl = "git log --oneline --graph --decorate";
      gla = "git log --oneline --graph --decorate --all";
      gp = "git push";
      gpf = "git push --force-with-lease";
      gpu = "git push -u origin HEAD";
      gpl = "git pull";
      gs = "git status";
      gss = "git status --short";
      gst = "git stash";
      gstp = "git stash pop";

      # Kubectl shortcuts
      k = "kubectl";
      kd = "kubectl describe";
      ke = "kubectl edit";
      kg = "kubectl get";
      kl = "kubectl logs";
      klf = "kubectl logs -f";
      ka = "kubectl apply -f";
      kdel = "kubectl delete";
      kex = "kubectl exec -it";

      # Databricks shortcuts
      db = "databricks";

      # Common shortcuts
      c = "clear";
      h = "history";
      y = "yazi";
      grep = "grep --color=auto";
      cat = "cat -v";
      mkdir = "mkdir -p";
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";

      # FZF with bat preview (from nix-config)
      fz = "fzf --preview 'bat --style=numbers --color=always --line-range :500 {}'";

    };

    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "sudo"
        "docker"
        "kubectl"
      ];
      theme = "robbyrussell";
    };

    initContent = ''
      export GOPATH="$HOME/go"
      export GOBIN="$GOPATH/bin"
      export PATH="$GOBIN:$PATH"

      # Some persisted shells can inherit tracing flags from prior sessions.
      # Clear them during init so command execution does not echo aliases/functions.
      unsetopt xtrace verbose 2>/dev/null || true
    '';
  };
}
