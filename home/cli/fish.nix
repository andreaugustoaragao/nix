{ config, pkgs, lib, inputs, ... }:

{
  # Fish shell configuration
  programs.fish = {
    enable = true;
    
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
      cd = "z";  # Use zoxide instead of cd
      
      # FZF with bat preview (from nix-config)
      fz = "fzf --preview 'bat --style=numbers --color=always --line-range :500 {}'";
    };
    
    interactiveShellInit = ''
      # Zoxide integration
      zoxide init fish | source
      
      # Any-nix-shell integration for better nix-shell experience
      ${pkgs.any-nix-shell}/bin/any-nix-shell fish --info-right | source
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
        name = "z";
        src = pkgs.fishPlugins.z.src;
      }
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