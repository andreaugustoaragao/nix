{ config, pkgs, lib, inputs, ... }:

{
  environment.enableDebugInfo = false;

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    age
    htop
    tree
    uwsm
    claude-code
    inotify-tools
    psmisc
    nettools
    inetutils  # provides telnet and hostname
    hostname   # explicit hostname package for scripts
    smem
    procps
    lsof
    bc
    yq
    valgrind
    elfutils
    glib

    # Development tools moved to home/cli/development.nix for better security
    # Only keeping essential system-level packages here

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

    # Audio diagnostic tools
    pciutils  # provides lspci
    usbutils  # provides lsusb
    alsa-utils  # provides aplay, arecord, amixer
    pulseaudio  # provides pactl for PulseAudio compatibility diagnostics

    nautilus

    # Spell checking dictionaries
    hunspell
    hunspellDicts.en_US-large
    hunspellDicts.en_GB-large

    # Development tools moved to home configuration
  ];
} 