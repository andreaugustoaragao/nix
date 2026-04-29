{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  imports = [
    ./hyprland.nix
    ./niri.nix
    ./wayland-services.nix
    ./wofi.nix
    ./fuzzel.nix
    ./wlogout.nix
    ./lockscreen.nix
    ./mako.nix
    ./gtk.nix
    ./qt.nix
    ./ghostty.nix
    ./foot.nix
    ./kitty.nix
    ./alacritty.nix
    ./swayosd.nix
    ./hyprpaper.nix
    ./uwsm.nix
    ./screenshot.nix
    ./brave.nix
    ./google-chrome.nix
    ./firefox.nix
    ./qutebrowser.nix
    ./vscode.nix
    ./zed.nix
    ./waybar.nix
    ./eww.nix
    ./wallpapers.nix
    ./fcitx.nix
    ./thunar.nix
    ./xresources.nix
    ./cursors.nix
    ./mimeapps.nix
    ./notes.nix
    ./window-switcher.nix
    ./web-apps-launcher.nix
    ./do-not-disturb.nix
    ./quickshell.nix
    ./matugen.nix
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
    "${pkgs-unstable.code-cursor}/share/pixmaps/cursor.png";

  home.packages =
    with pkgs;
    [
      pavucontrol
      xdg-desktop-portal-gnome
      xdg-desktop-portal-gtk
      teams-for-linux
      pkgs-unstable.telegram-desktop
      bitwarden-desktop
      pkgs-unstable.code-cursor
      neovide
      sniffnet
      swayimg
      obsidian
      qt6.qttools

      # Video-related packages
      mpv
      obs-studio
      obs-studio-plugins.advanced-scene-switcher
      kdePackages.kdenlive
    ]
    ++ lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") [
      zoom-us
    ];
}
