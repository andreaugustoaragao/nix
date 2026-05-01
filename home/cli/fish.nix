{ config, pkgs, lib, inputs, ... }:

{
  # Fish shell configuration
  programs.fish = {
    enable = true;
    
    # Aliases are commands fish silently substitutes — used here for
    # cases that override or transform a real command (eza-as-ls,
    # safer rm/cp/mv) where seeing the expansion every time is noise.
    shellAliases = {
      # File listing — eza with our preferred flags
      ls = "eza -lh --group-directories-first --icons=auto";
      lsa = "eza -lh --group-directories-first --icons=auto -a";
      lt = "eza --tree --level=2 --long --icons --git";
      lta = "eza --tree --level=2 --long --icons --git -a";
      ll = "ls -alF";
      la = "ls -A";
      l = "ls -CF";

      # Safety/coloring overrides on stdlib commands
      grep = "grep --color=auto";
      cat = "cat -v";
      mkdir = "mkdir -p";
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";

      # Composed
      fz = "fzf --preview 'bat --style=numbers --color=always --line-range :500 {}'";
    };

    # Abbreviations expand inline as you type — `g<space>` becomes
    # `git `. You see the full command before running it, history
    # records the expanded form, and tab-completion works on the
    # expanded command. Preferred over aliases for any prefix-style
    # shortcut where the expansion is informative.
    shellAbbrs = {
      # System management
      rebuild = "sudo nixos-rebuild switch --flake .";
      update = "nix flake update";
      nixf = "nix search nixpkgs";

      # Editor
      v = "nvim";
      vim = "nvim";
      vi = "nvim";

      # Git
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

      # Kubernetes
      k = "kubectl";
      kd = "kubectl describe";
      ke = "kubectl edit";
      kg = "kubectl get";
      kl = "kubectl logs";
      klf = "kubectl logs -f";
      ka = "kubectl apply -f";
      kdel = "kubectl delete";
      kex = "kubectl exec -it";

      # Databricks
      db = "databricks";

      # Misc shortcuts
      c = "clear";
      h = "history";
      y = "yazi";
    };
    
    interactiveShellInit = ''
      # Any-nix-shell integration for better nix-shell experience
      ${pkgs.any-nix-shell}/bin/any-nix-shell fish --info-right | source

      # zoxide replaces `cd` in interactive fish only — zsh/bash get
      # the default `z` alias (so non-interactive scripts and CLI
      # agents that source those shells keep POSIX cd semantics).
      ${pkgs.zoxide}/bin/zoxide init fish --cmd cd | source

      # Use local k3s kubeconfig when no KUBECONFIG is set
      if test -r /etc/rancher/k3s/k3s.yaml; and not set -q KUBECONFIG
        set -gx KUBECONFIG /etc/rancher/k3s/k3s.yaml
      end

      # Puppeteer / Chrome DevTools MCP
      set -gx PUPPETEER_EXECUTABLE_PATH /etc/profiles/per-user/aragao/bin/brave
    '';
    
    functions = {
      fish_greeting = {
        description = "Show fastfetch and colorful fortune on startup";
        body = ''
          # Display system information first
          fastfetch
          
          # Display a colorful random fortune below
          if command -v fortune >/dev/null 2>&1 && command -v lolcat >/dev/null 2>&1
            echo
            fortune | lolcat
          else if command -v fortune >/dev/null 2>&1
            echo
            fortune
          end
        '';
      };
    };
    
    plugins = [
      {
        name = "fzf-fish";
        src = pkgs.fishPlugins.fzf-fish.src;
      }
      {
        name = "autopair";
        src = pkgs.fishPlugins.autopair.src;
      }
    ];
  };
} 