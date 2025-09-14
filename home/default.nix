{ config, pkgs, lib, inputs, owner, ... }:

{
  # Import LazyVim configuration
  imports = [
    ./desktop
    ./cli
    ./services
    ./fonts.nix
  ];
  
  home.username = owner.name;
  home.homeDirectory = "/home/${owner.name}";
  home.stateVersion = "24.11";  # Auto-rebuild test

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # Enable XDG user directories - only the directories you want
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    desktop = null;  # Disable Desktop folder
    templates = null;  # Disable Templates folder
    publicShare = null;  # Disable Public folder
    documents = null;  # Disable Documents folder
    download = "${config.home.homeDirectory}/downloads";
    music = "${config.home.homeDirectory}/music";
    pictures = "${config.home.homeDirectory}/pictures";
    videos = "${config.home.homeDirectory}/videos";
    
    # Custom project directories
    extraConfig = {
      XDG_PROJECTS_DIR = "${config.home.homeDirectory}/projects";
      XDG_WORK_DIR = "${config.home.homeDirectory}/projects/work";
      XDG_PERSONAL_DIR = "${config.home.homeDirectory}/projects/personal";
    };
  };

  # Ensure project directories are created via Home Manager activation
  home.activation.createProjectDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Create project directories
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/projects/work"
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/projects/personal"
    echo "Created project directories"
  '';

  # Prevent Home Manager backup collisions (e.g., .gtkrc-2.0.hm-backup2)
  home.activation.cleanupHmBackups = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Remove stale Home Manager backup files that can block activation
    rm -f "$HOME/.gtkrc-2.0.hm-backup"* || true
  '';

}
# verify Fri Sep 12 04:54:13 PM MDT 2025

