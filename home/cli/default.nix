{
  pkgs,
  lib,
  inputs,
  # Provided via specialArgs in flake.nix; safe to use in `imports`.
  # Reading pkgs.stdenv.hostPlatform inside imports triggers infinite
  # recursion since pkgs comes from _module.args, which depends on
  # config, which depends on imports being resolved.
  isDarwinHost ? false,
  ...
}:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  # pkgs.stdenv.hostPlatform.isLinux IS safe inside `config = { ... }`
  # (post-evaluation), so we keep this binding for the home.packages
  # and xdg.desktopEntries gates below.
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in
{
  imports = [
    ./zsh.nix
    ./fish.nix
    ./tmux.nix
    ./starship.nix
    ./zoxide.nix
    ./atuin.nix
    ./mise.nix
    ./carapace.nix
    ./pay-respects.nix
    ./git.nix
    ./fastfetch.nix
    ./btop.nix
    ./nvim-lazyvim.nix
    ./development.nix
    ./claude.nix
    ./codex.nix
    ./k9s.nix
    ./fzf.nix
    ./pi.nix
    # Cross-platform programs.ssh — defines the github-personal /
    # github-work host aliases that point at sops-decrypted identity
    # files. Loaded on Linux and macOS; agent/askpass wiring stays
    # platform-specific (see gpg.nix on Linux).
    ./ssh-config.nix
  ]
  ++ lib.optionals (!isDarwinHost) [
    # gpg/ssh-agent management here is built on systemd-user units +
    # Linux paths (pinentry-qt, gcr-ssh-agent masking). macOS uses
    # launchd + the system keychain; wire that separately if needed.
    ./gpg.nix
    ./ssh-add-keys.nix
    ./gpg-add-keys.nix
    # `xdg.desktopEntries` is a Linux-only HM option (the option name
    # itself is undefined on Darwin), so the entire feature lives in a
    # separately-imported module.
    ./desktop-entries.nix
  ]
  ++ lib.optionals isDarwinHost [
    # AeroSpace tiling-WM config — niri's closest macOS analog. The
    # binary itself is installed via the homebrew cask in
    # darwin/homebrew.nix; this module only owns ~/.config/aerospace.
    ./aerospace.nix
    # Ghostty config — same font/theme/opacity as the Linux side. The
    # module is platform-aware and skips the nixpkgs ghostty install on
    # Darwin (where the homebrew cask provides it).
    ../desktop/ghostty.nix
    # Wallpaper image derivation. Linux pulls this in via
    # home/desktop/default.nix; on macOS we need it for
    # ./macos-wallpaper.nix to reference.
    ../desktop/wallpapers.nix
    # Apply the macOS desktop wallpaper via AppleScript on every HM
    # activation. Pulls from the wallpapers derivation above.
    ./macos-wallpaper.nix
    # Generate one `.app` bundle per entry in
    # home/desktop/web-apps-data.nix so each web app gets a Spotlight
    # / Raycast / Launchpad / AeroSpace launcher. Ships a Darwin
    # `browser-app` script alongside.
    ../desktop/web-apps-macos.nix
  ];

  home.packages =
    with pkgs;
    [
      # System utilities
      file
      fzf

      # Cloud packages
      azure-cli
      awscli2
      databricks-cli
      google-cloud-sdk
      kubectl
      kubernetes-helm
      kubectx
      stern
      ansible
      # terraform, terragrunt, packer: HashiCorp relicensed all three to
      # BSL in 2023. nixpkgs treats BSL as unfree → cache.nixos.org has
      # no prebuilt binaries → builds from source → packer's go test
      # suite SIGABRTs on aarch64-darwin in 25.11. Linux-only block
      # below re-adds them where the cache works.

      # General tools
      code2prompt # CLI tool with token counting functionality
      bitwarden-cli
      curlie
      xh
      wget
      aria2
      ddgr # DuckDuckGo search from the terminal
      rsync
      openssh
      mosh
      tmux
      screen
      htop
      nmap
      tcpdump
      socat
      netcat
      dig
      whois
      mtr
      iperf
      speedtest-cli
      neofetch
      screenfetch
      lolcat
      figlet
      toilet
      cowsay
      fortune
      cmatrix
      tree
      ncdu
      gdu
      duf
      progress
      pv
      moreutils
      entr
      watchman
      cachix

      # Rust-based coreutils and modern replacements
      ripgrep
      fd
      bat
      eza
      lsd
      dust
      bottom
      delta
      procs
      hyperfine
      bandwhich
      dog
      tokei
      uutils-coreutils
      broot
      sd
      choose
      hexyl
      grex
      zoxide
      skim
      tealdeer
      just
      watchexec
      onefetch
      difftastic
      jless
      qsv
      csvlens
      viu
      pastel
      ouch
      unzip
      zip
      yazi
      inkscape
      imagemagick # provides convert command

      # Snacks.image inline-render dependencies (nvim opens images
      # rendered through these CLIs via the kitty graphics protocol):
      #   - ghostscript → `gs` for embedded PDF rendering
      #   - tectonic    → lightweight LaTeX engine for math expressions
      #   - mermaid-cli → `mmdc` for Mermaid diagrams (pulls Chromium)
      ghostscript
      tectonic
      mermaid-cli

      # Development tools that moved to development.nix:
      # - All language servers, compilers, and dev tools
      # - cargo-*, gitui, jq, httpie moved to development.nix
      # - direnv moved to development.nix as a program
    ]
    ++ [
      # zellij 0.44.1 in nixos-25.11 channel needs rustc 1.92 but the
      # channel ships 1.91.1; use unstable until the channel revert
      # (NixOS/nixpkgs#512626) propagates.
      unstable-pkgs.zellij
    ]
    ++ lib.optionals isLinux (with pkgs; [
      # Linux-only / not built on Darwin in nixpkgs. Anything here
      # either needs procfs, an X server, OpenGL, or a Linux kernel
      # API (inotify, BPF, etc.).
      libnotify # notify-send (uses dbus)
      iotop
      nethogs
      iftop
      wireshark-cli
      sl
      dfc
      inotify-tools
      lorri
      mesa-demos # glxinfo for OpenGL debugging
      podman-compose
      # macOS ships traceroute in /usr/sbin/traceroute; the nixpkgs
      # build is Linux-only.
      traceroute
      # HashiCorp BSL-licensed tools — see comment above. Re-added
      # here so they keep working on Linux where nixpkgs CI does push
      # binary substitutes despite the unfree flag.
      terraform
      terragrunt
      packer
    ]);

  programs.bat = {
    enable = true;
    config.theme = "Catppuccin Mocha";
  };
}
