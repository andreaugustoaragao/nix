{
  config,
  lib,
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

  # Default _module.args so headless hosts (tala / mac-work) can import
  # ./cli without the wallpapers derivation pulled in by ./desktop. The
  # NixOS module system constructs an explicit args attrset for every
  # formal in a module function, so a bare `wallpapers ? null` default
  # inside fastfetch.nix is never reached — the system forces the
  # _module.args lookup first. Override happens at priority 100 in
  # ./desktop/wallpapers.nix on graphical hosts.
  _module.args.wallpapers = lib.mkDefault null;

  # XDG user directories are a Linux desktop concept (~/.config/user-dirs.dirs
  # consumed by GNOME/KDE/file managers). macOS has its own ~/Pictures,
  # ~/Downloads layout managed by the OS — leave it alone there.
  xdg.userDirs = lib.mkIf (!isDarwinHost) {
    enable = true;
    createDirectories = true;
    # 26.05 flipped this default to false; pin true to keep exporting the
    # XDG_*_DIR variables into the session as before.
    setSessionVariables = true;
    desktop = null;
    templates = null;
    publicShare = null;
    documents = null;
    download = "${config.home.homeDirectory}/downloads";
    music = "${config.home.homeDirectory}/music";
    pictures = "${config.home.homeDirectory}/pictures";
    videos = "${config.home.homeDirectory}/videos";

    extraConfig = {
      PROJECTS = "${config.home.homeDirectory}/projects";
      WORK = "${config.home.homeDirectory}/projects/work";
      PERSONAL = "${config.home.homeDirectory}/projects/personal";
    };
  };

}
# verify Fri Sep 12 04:54:13 PM MDT 2025
