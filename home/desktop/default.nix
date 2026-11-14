{
  pkgs,
  lib,
  unstable-pkgs,
  hostName,
  personalOnly,
  ...
}:
{
  imports = [
    # Typed my.displays.* options — single entry point for the
    # dp1/dp2 slot metadata resolved in flake.nix. Import first so
    # consumers below can read config.my.displays.
    ./display-options.nix
    ./hyprland.nix
    ./niri.nix
    ./portal.nix
    ./wayland-services.nix
    ./fuzzel.nix
    ./wlogout.nix
    ./lockscreen.nix
    ./mako.nix
    ./gtk.nix
    ./qt.nix
    ./kitty.nix
    ./swayosd.nix
    ./hyprpaper.nix
    ./uwsm.nix
    ./screenshot.nix
    ./brave.nix
    ./agent-browsers.nix
    # Pin Brave's Personal/ and Work/ profile dirs so display names
    # stay in lockstep with --profile-directory used by the web-app
    # launchers. Ships a `brave-profiles-reset` script. See module
    # header for the workflow.
    ./brave-profiles.nix
    ./google-chrome.nix
    ./zed.nix
    ./folio.nix
    ./waybar.nix
    ./wallpapers.nix
    ./fcitx.nix
    ./thunar.nix
    ./vereda.nix
    ./xresources.nix
    ./cursors.nix
    ./mimeapps.nix
    ./window-switcher.nix
    ./web-apps-launcher.nix
    ./do-not-disturb.nix
    ./quickshell.nix
    ./noctalia.nix
    ./matugen.nix
  ]
  ++ lib.optionals (hostName != "prl-dev-vm") [
    ./wofi.nix
    ./eww.nix
    ./vscode.nix
    ./ghostty.nix
    ./foot.nix
    ./alacritty.nix
  ]
  ++ lib.optionals (!personalOnly) [
    ./fulcrum.nix
    ./notes.nix
  ]
  ++ lib.optionals (hostName == "prl-dev-vm") [
    ./herdr-layouts.nix
    ./parallels-displays.nix
  ];

  # Install extensions for Cursor (not managed by programs.vscode)
  home.activation.installCursorExtensions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v cursor &>/dev/null; then
      cursor --install-extension qwtel.sqlite-viewer 2>/dev/null || true
      cursor --install-extension zaaack.markdown-editor 2>/dev/null || true
    fi
  '';

  # Cursor's icon ships in share/pixmaps/ which fuzzel doesn't search.
  # Surfacing it under the hicolor theme so .desktop's Icon=cursor
  # resolves in launchers.
  xdg.dataFile."icons/hicolor/512x512/apps/cursor.png".source =
    "${unstable-pkgs.code-cursor}/share/pixmaps/cursor.png";

  home.packages =
    with pkgs;
    [
      pavucontrol
      unstable-pkgs.telegram-desktop
      bitwarden-desktop
      unstable-pkgs.code-cursor
      sniffnet
      qt6.qttools
      (pkgs.callPackage ../../pkgs/pdfcraft.nix { })

      # Video-related packages
      snapshot
      mpv
      obs-studio
      obs-studio-plugins.advanced-scene-switcher
      kdePackages.kdenlive
    ]
    ++ lib.optionals (hostName != "prl-dev-vm") [
      easyeffects
      freelens-bin
      neovide
      obsidian
      swayimg
    ]
    ++ lib.optionals (!personalOnly && hostName != "prl-dev-vm") [ teams-for-linux ]
    ++ lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") [
      zoom-us
      aptakube
    ]
    ++ lib.optionals (hostName == "prl-dev-vm") [
      playerctl
      (pkgs.callPackage ../../pkgs/herdr-app.nix { })
      (pkgs.callPackage ../../pkgs/herdr-core.nix { })
      (pkgs.callPackage ../../pkgs/vitals.nix { })
    ];
}
