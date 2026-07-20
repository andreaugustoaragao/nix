{
  pkgs,
  lib,
  unstable-pkgs,
  isVm,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  # Parallels' guest 3D driver tops out at OpenGL 4.0/4.1, but ghostty
  # >=1.3 requires 4.3. Force Mesa to use llvmpipe (software, OpenGL
  # 4.5+) for ghostty only — scoped via wrapper so other GL apps keep
  # using the accelerated guest driver.
  ghosttyPkg =
    if isVm then
      pkgs.symlinkJoin {
        name = "ghostty-vm-${unstable-pkgs.ghostty.version}";
        paths = [ unstable-pkgs.ghostty ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/ghostty \
            --set LIBGL_ALWAYS_SOFTWARE 1
        '';
      }
    else
      unstable-pkgs.ghostty;
in
{
  # Ghostty binary: installed via nix on Linux, via the homebrew cask on
  # macOS (declared in darwin/homebrew.nix). The brew build is
  # notarized + signed and integrates with the macOS keychain in ways
  # the nixpkgs darwin build currently does not.
  home.packages = lib.optionals isLinux [ ghosttyPkg ];

  # Expose Ghostty's CLI on PATH on macOS. The brew cask installs the
  # binary inside the .app bundle and doesn't symlink a launcher, so
  # things like snacks.image's tool-availability probe and shell
  # scripts can't find `ghostty`. ~/.local/bin is already on
  # `home.sessionPath` (see home/default.nix).
  home.activation.ghosttyCliSymlink = lib.mkIf (!isLinux) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "$HOME/.local/bin"
      $DRY_RUN_CMD ln -sfn \
        "/Applications/Ghostty.app/Contents/MacOS/ghostty" \
        "$HOME/.local/bin/ghostty"
    ''
  );

  # Ghostty reads $XDG_CONFIG_HOME/ghostty/config on both Linux and
  # macOS, so a single declarative config covers both platforms.
  xdg.configFile."ghostty/config".text = ''
    font-family = CaskaydiaMono Nerd Font
    font-size = 11

    ${lib.optionalString isLinux ''
      # Single-instance: subsequent invocations open a new window in
      # the existing process (analogous to footclient or kitty
      # --single-instance). GTK-only — macOS Ghostty is already
      # single-process by default.
      gtk-single-instance = true
    ''}

    shell-integration = fish
    # Absolute path: on macOS Ghostty wraps `command` in
    # `/usr/bin/login -fl <user> /bin/bash --noprofile --norc -c "exec -l <command>"`,
    # so bash never sees the nix PATH and a bare `fish` resolves to nothing.
    command = ${pkgs.fish}/bin/fish

    # Always open new windows/tabs/surfaces in $HOME, regardless of
    # the launcher's cwd. AeroSpace inherits cwd=/ from launchd and
    # passes that to Ghostty when binding `exec-and-forget`, which
    # would otherwise drop new shells at the filesystem root.
    working-directory = home

    window-padding-x = 5
    window-padding-y = 5
    # window-theme defaults to "auto" — follows the freedesktop
    # color-scheme preference so GTK chrome flips with system mode.

    # Translucent terminal — cells using the default bg render at this
    # opacity (so wallpaper bleeds through). Cells with explicit bg
    # colors stay fully opaque, which is how tmux's active pane
    # (window-active-style bg=<surface hex>) reads as "solid" while
    # inactive panes (bg=default) fade to wallpaper.
    background-opacity = 0.85
    background-blur-radius = 20

    # No window chrome. On Linux we drop the decoration entirely; on
    # macOS the borderless NSWindow path forces square corners (which
    # JankyBorders then traces as a square outline), so keep the
    # standard window and just hide the titlebar strip.
    ${lib.optionalString isLinux ''
      window-decoration = false
    ''}
    ${lib.optionalString (!isLinux) ''
      macos-titlebar-style = hidden

      # macOS apps stay running after their last window closes by
      # platform convention; opt out so Ghostty exits with its UI.
      quit-after-last-window-closed = true
    ''}

    unfocused-split-opacity = 0.9
    copy-on-select = false
    # Close windows/splits without the "are you sure?" prompt.
    confirm-close-surface = false

    # Disable Ghostty's built-in update path. On Linux the package
    # manager owns upgrades; on macOS the homebrew cask + nix-darwin
    # activation upgrades on every rebuild (see
    # darwin/homebrew.nix:onActivation.upgrade). Setting this to
    # `off` also suppresses Sparkle's first-launch "enable automatic
    # updates?" dialog on macOS.
    auto-update = off

    # Tame mouse-wheel scroll speed (default 1.0 jumps several lines
    # per notch on high-resolution wheels). 0.4 matches niri's
    # mouse.scroll-factor in this repo.
    mouse-scroll-multiplier = 0.4

    # Full silence: don't ring the bell when long commands finish, and
    # disable every bell-feature so DMS/niri don't get an attention
    # signal that gets routed to the freedesktop alert sound theme.
    notify-on-command-finish-action = no-bell,no-notify
    bell-features = no-system,no-audio,no-attention,no-title,no-border

    # Auto-switch via freedesktop portal color-scheme. Both themes ship
    # with ghostty — no extra files to manage.
    theme = light:TokyoNight Day,dark:Catppuccin Mocha
  '';
}
