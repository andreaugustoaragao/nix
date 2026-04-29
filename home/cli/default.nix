{ pkgs, inputs, ... }:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  # Upstream lfk's flake.nix declares a stale `vendorHash` that doesn't
  # match what `go mod download` actually produces (their CI doesn't run
  # `nix build`, so the drift went unnoticed). Patch the goModules
  # derivation's outputHash to the hash nix computes locally so the
  # build is reproducible. Re-check this value after each
  # `nix flake update lfk`.
  lfk =
    let
      base = inputs.lfk.packages.${pkgs.stdenv.hostPlatform.system}.default;
    in
    base.overrideAttrs (_: {
      goModules = base.goModules.overrideAttrs (_: {
        outputHash = "sha256-Da/VSnqvybfAAKz2txoOPOAjf/sI8NftGo6JNye/bwk=";
      });
    });
in
{
  imports = [
    ./zsh.nix
    ./fish.nix
    ./tmux.nix
    ./starship.nix
    ./zoxide.nix
    ./git.nix
    ./gpg.nix
    ./ssh-add-keys.nix
    ./gpg-add-keys.nix
    ./fastfetch.nix
    ./btop.nix
    ./nvim-lazyvim.nix
    ./development.nix
    ./claude.nix
    ./k9s.nix
  ];

  home.packages = with pkgs; [
    # System utilities
    libnotify # provides notify-send
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
    lfk
    terraform
    terragrunt
    ansible
    packer
    podman-compose

    # General tools
    code2prompt # CLI tool with token counting functionality
    bitwarden-cli
    curlie
    xh
    wget
    aria2
    rsync
    openssh
    mosh
    tmux
    screen
    htop
    iotop
    nethogs
    iftop
    nmap
    tcpdump
    wireshark-cli
    socat
    netcat
    dig
    whois
    mtr
    traceroute
    iperf
    speedtest-cli
    neofetch
    screenfetch
    lolcat
    figlet
    toilet
    cowsay
    fortune
    sl
    cmatrix
    tree
    ncdu
    gdu
    duf
    dfc
    progress
    pv
    moreutils
    entr
    watchman
    inotify-tools
    lorri
    cachix
    mesa-demos # provides glxinfo for OpenGL debugging

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
    starship
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
    yazi
    inkscape
    imagemagick # provides convert command

    # Development tools that moved to development.nix:
    # - All language servers, compilers, and dev tools
    # - cargo-*, gitui, jq, httpie moved to development.nix
    # - direnv moved to development.nix as a program
  ] ++ [
    # zellij 0.44.1 in nixos-25.11 channel needs rustc 1.92 but the
    # channel ships 1.91.1; use unstable until the channel revert
    # (NixOS/nixpkgs#512626) propagates.
    unstable-pkgs.zellij
  ];

  # Local .desktop overrides for packages whose Icon= references a name
  # not in the active icon theme (Papirus-Dark). User-local entries win
  # over the package-provided ones in the XDG search path.
  xdg.desktopEntries = {
    yazi = {
      name = "Yazi";
      comment = "Blazing fast terminal file manager written in Rust";
      exec = "yazi %u";
      terminal = true;
      type = "Application";
      mimeType = [ "inode/directory" ];
      categories = [ "Utility" "FileTools" "FileManager" "ConsoleOnly" ];
      icon = "system-file-manager";
    };

    # khal ships no Icon= field at all.
    khal = {
      name = "ikhal";
      genericName = "Calendar application";
      comment = "Terminal CLI calendar application";
      exec = "ikhal";
      terminal = true;
      type = "Application";
      categories = [ "Calendar" "ConsoleOnly" ];
      icon = "office-calendar";
    };

    # blueman ships Icon=blueman-device which isn't in Papirus.
    blueman-adapters = {
      name = "Bluetooth Adapters";
      comment = "Set Bluetooth Adapter Properties";
      exec = "blueman-adapters";
      terminal = false;
      type = "Application";
      categories = [ "Settings" "HardwareSettings" ];
      icon = "blueman";
    };
  };
}
