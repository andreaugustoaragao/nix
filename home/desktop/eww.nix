{
  pkgs,
  ...
}:

let
  # Test rice — Kanjurito's full Catppuccin-themed eww bar (niri-aware).
  # Pinned to a specific commit for reproducibility; update with a fresh
  # `nix-prefetch-url --unpack <archive>` to bump.
  kanjurito = pkgs.fetchFromGitHub {
    owner = "Kanjurito";
    repo = "dotfiles";
    rev = "03a67e16255574fe70c76e92a549dbe6fc1d1d8b";
    sha256 = "08ql141x8c3i2y51q9h8ybdr8ngh3lqgs0ipzygl548cbdhxj7m9";
  };
in
{
  home.packages = with pkgs; [
    eww

    # Core tools
    jq
    curl
    coreutils
    gnugrep
    iproute2
    libnotify

    # Audio / media
    pamixer
    pavucontrol
    pulseaudio
    playerctl
    cava

    # Hardware controls
    brightnessctl
    acpi
    upower

    # Network / bluetooth (panels in the bar)
    networkmanager
    bluez
    bluez-tools

    # Build tools eww needs at runtime for SCSS
    sassc
  ];

  # Drop Kanjurito's eww config tree into ~/.config/eww as individual
  # symlinks so future per-widget tweaks don't require unmounting the
  # whole thing. The actual bar lives at ~/.config/eww/bar.
  xdg.configFile."eww" = {
    source = "${kanjurito}/eww";
    recursive = true;
  };
}
