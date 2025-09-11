{ config, pkgs, lib, inputs, ... }:

{
  environment.enableDebugInfo = false;

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tree
    uwsm
    claude-code
    inotify-tools
    psmisc
    nettools
    smem
    procps
    lsof
    bc
    valgrind
    elfutils
    glib

    nil
    nixfmt-rfc-style
    bash-language-server
    marksman
    pyright
    gopls
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    jdt-language-server

    python3
    uv
    go
    nodejs_22
    openjdk21

    ripgrep
    fd
    bat
    eza
    lsd
    dust
    zoxide
    bottom
    delta
    procs
    hyperfine
    bandwhich
    dog
    tokei
    uutils-coreutils

    duf
    broot
    sd
    choose
    hexyl
    grex

    pamixer
    brightnessctl

    nautilus

    # Added Go/Java developer tools
    delve
    golangci-lint
    maven
    gradle
  ];
} 