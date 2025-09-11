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
    ./development.nix
  ];


 home.packages = with pkgs; [
    # System utilities
    libnotify  # provides notify-send
    fzf

    # Cloud packages  
    azure-cli
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
    podman-compose

    # General tools
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
    
    # Development tools that moved to development.nix:
    # - All language servers, compilers, and dev tools
    # - cargo-*, gitui, jq, httpie moved to development.nix
    # - direnv moved to development.nix as a program
  ];
} 