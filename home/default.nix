{
  config,
  lib,
  pkgs,
  owner,
  isServer ? false,
  # Comes from flake.nix specialArgs. Using pkgs.stdenv.hostPlatform here
  # would recurse: imports must evaluate before _module.args resolves pkgs.
  isDarwinHost ? false,
  homePrefix ? "/home",
  ...
}:

{
  # Import LazyVim configuration
  imports = [
    ./cli
    ./fonts.nix
    # User services index is platform-aware: Linux pulls in
    # systemd-user units (notes-sync, fulcrum, darkman, local-llm),
    # Darwin pulls in the launchd-agent counterparts (currently just
    # notes-sync). Per-file gating lives in services/default.nix.
    ./services
  ]
  ++ lib.optionals (!isDarwinHost) [
    # Desktop helper scripts — eww/notify-send/Linux paths, including
    # /run/secrets/. Port piecemeal if needed.
    ./scripts
  ]
  ++ lib.optionals (!isServer && !isDarwinHost) [
    # Wayland desktop stack — Hyprland, niri, waybar, fcitx, etc.
    ./desktop
  ];

  home = {
    username = owner.name;
    homeDirectory = "${homePrefix}/${owner.name}";
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

  # XDG user directories are a Linux desktop concept (~/.config/user-dirs.dirs
  # consumed by GNOME/KDE/file managers). macOS has its own ~/Pictures,
  # ~/Downloads layout managed by the OS — leave it alone there.
  xdg.userDirs = lib.mkIf (!isDarwinHost) {
    enable = true;
    createDirectories = true;
    desktop = null;
    templates = null;
    publicShare = null;
    documents = null;
    download = "${config.home.homeDirectory}/downloads";
    music = "${config.home.homeDirectory}/music";
    pictures = "${config.home.homeDirectory}/pictures";
    videos = "${config.home.homeDirectory}/videos";

    extraConfig = {
      XDG_PROJECTS_DIR = "${config.home.homeDirectory}/projects";
      XDG_WORK_DIR = "${config.home.homeDirectory}/projects/work";
      XDG_PERSONAL_DIR = "${config.home.homeDirectory}/projects/personal";
    };
  };

}
# verify Fri Sep 12 04:54:13 PM MDT 2025
