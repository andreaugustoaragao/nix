{ config, pkgs, lib, inputs, ... }:

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
  ];


 home.packages = with pkgs; [
    # System utilities
    libnotify  # provides notify-send
    fzf

    # Cloud packages  
    azure-cli
    awscli2
    databricks-cli
    google-cloud-sdk
    kubectl
    kubernetes-helm
    k9s
    kubectx
    stern
    terraform
    terragrunt
    ansible
    packer
    podman-compose

    # General tools
    code2prompt  # CLI tool with token counting functionality
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
    mesa-demos  # provides glxinfo for OpenGL debugging

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
    zellij
    yazi
    inkscape
    imagemagick  # provides convert command
    
    # Development tools that moved to development.nix:
    # - All language servers, compilers, and dev tools
    # - cargo-*, gitui, jq, httpie moved to development.nix
    # - direnv moved to development.nix as a program
  ];
} 