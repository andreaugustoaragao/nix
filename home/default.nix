{
  config,
  lib,
  owner,
  isServer ? false,
  ...
}:

{
  # Import LazyVim configuration
  imports = [
    ./cli
    ./services
    ./scripts
    ./fonts.nix
  ]
  ++ lib.optionals (!isServer) [
    ./desktop
  ];

  home = {
    username = owner.name;
    homeDirectory = "/home/${owner.name}";
    stateVersion = "24.11"; # Auto-rebuild test

    # Prioritize ~/.local/bin in PATH
    sessionPath = [
      "$HOME/.local/bin"
    ];

    activation = {
      # Ensure project directories are created via Home Manager activation
      createProjectDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        # Create project directories
        $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/projects/work"
        $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/projects/personal"
        echo "Created project directories"
      '';

      # Prevent Home Manager backup collisions (e.g., .gtkrc-2.0.hm-backup2)
      cleanupHmBackups = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        # Remove stale Home Manager backup files that can block activation
        rm -f "$HOME/.gtkrc-2.0.hm-backup"* || true
      '';
    };
  };

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # Enable XDG user directories - only the directories you want
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    desktop = null; # Disable Desktop folder
    templates = null; # Disable Templates folder
    publicShare = null; # Disable Public folder
    documents = null; # Disable Documents folder
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

}
# verify Fri Sep 12 04:54:13 PM MDT 2025
