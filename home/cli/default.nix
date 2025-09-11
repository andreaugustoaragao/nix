{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ./zsh.nix
    ./fish.nix
    ./tmux.nix
    ./starship.nix
    ./zoxide.nix
    ./git.nix
    ./fastfetch.nix
    ./btop.nix
    ./nvim-lazyvim.nix
  ];


 home.packages = with pkgs; [
    # Existing packages
    libnotify  # provides notify-send
    fzf
    azure-cli

    # Development packages
    gcc
    gdb
    lldb
    valgrind
    strace
    ltrace
    cmake
    meson
    ninja
    pkg-config
    rustc
    cargo
    rust-analyzer
    rustfmt
    clippy
    python311
    python311Packages.pip
    python311Packages.virtualenv
    python311Packages.black
    python311Packages.isort
    python311Packages.flake8
    python311Packages.mypy
    nodePackages.npm
    nodePackages.yarn
    nodePackages.pnpm
    typescript
    nodePackages.prettier
    shellcheck
    shfmt
    jq
    yq
    yamllint
    hadolint

    # Cloud packages
    awscli2
    google-cloud-sdk
    kubectl
    kubernetes-helm
    k9s
    kubectx
    terraform
    terragrunt
    ansible
    packer
    docker-compose
    podman-compose

    # General tools
    httpie
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
    tree
    ncdu
    duf
    dfc
    progress
    pv
    moreutils
    entr
    watchman
    inotify-tools
    direnv
    lorri
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
    starship
    just
    watchexec
    cargo-edit
    cargo-watch
    cargo-expand
    cargo-outdated
    cargo-udeps
    cargo-tarpaulin
    cargo-audit
    cargo-deny
    bacon
    gitui
    onefetch
    difftastic
    jless
    qsv
    csvlens
    viu
    pastel
    ouch
    zellij
    helix
  ];
} 