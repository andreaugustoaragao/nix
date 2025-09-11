{ config, pkgs, lib, inputs, ... }:

{
  # Git configuration with conditional includes
  programs.git = {
    enable = true;
    
    # Note: userName and userEmail are handled by conditional includes
    
    # Global git settings
    extraConfig = {
      init = {
        defaultBranch = "main";
      };
      pull = {
        rebase = false;
      };
      push = {
        default = "simple";
        autoSetupRemote = true;
      };
      core = {
        editor = "nvim";
        autocrlf = false;
        safecrlf = true;
      };
      merge = {
        conflictstyle = "diff3";
      };
      diff = {
        algorithm = "patience";
      };
      rerere = {
        enabled = true;
      };
      
      # Default user configuration (fallback for other directories)
      user = {
        name = "andreaugustoaragao";
        email = "andrearag@gmail.com";
      };
      
      # Conditional includes for different project directories
      includeIf."gitdir:~/projects/personal/" = {
        path = "~/.config/git/config-personal";
      };
      includeIf."gitdir:~/projects/work/" = {
        path = "~/.config/git/config-work";
      };
    };
    
    # Git aliases
    aliases = {
      st = "status";
      co = "checkout";
      br = "branch";
      ci = "commit";
      ca = "commit -a";
      cm = "commit -m";
      cam = "commit -am";
      df = "diff";
      dc = "diff --cached";
      lg = "log --oneline --graph --decorate --all";
      ll = "log --pretty=format:'%C(yellow)%h%Creset -%C(red)%d%Creset %s %C(bold blue)<%an>%Creset %C(green)(%cr)%Creset' --abbrev-commit";
      unstage = "reset HEAD --";
      last = "log -1 HEAD";
      visual = "!gitk";
    };
  };
  
  # Create personal git config
  xdg.configFile."git/config-personal".text = ''
    [user]
      name = andreaugustoaragao
      email = andrearag@gmail.com
    
    [commit]
      gpgsign = false
  '';
  
  # Create work git config  
  xdg.configFile."git/config-work".text = ''
    [user]
      name = andrearagao
      email = aragao@avaya.com
    
    [commit]
      gpgsign = false
  '';
} 