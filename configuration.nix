{ config, pkgs, lib, inputs, ... }:
#

{
  imports = [
    ./hardware-configuration.nix
    ./nvim-system.nix
    ./x11-dwm.nix
    ./st.nix
  ];

  # Centralized DPI configuration
  options.machine.dpi = lib.mkOption {
    type = lib.types.int;
    default = 144;
    description = "Default DPI to be used system-wide for X11 and applications";
  };

  config = {

  # Boot configuration for Parallels VM
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;  # Limit boot entries to save space
  boot.loader.efi.canTouchEfiVariables = true;
  
  # Use latest Linux kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;
  
  # Plymouth boot splash screen with custom theme (DISABLED - visual only, saves startup time)
  # boot.plymouth = {
  #   enable = true;
  #   theme = "rings";
  #   themePackages = with pkgs; [
  #     (adi1090x-plymouth-themes.override {
  #       selected_themes = [ "rings" ];
  #     })
  #   ];
  # };
  
  # Silent boot configuration for cleaner boot experience
  boot.consoleLogLevel = 3;
  boot.initrd.verbose = false;
  boot.kernelParams = [
    "quiet"
    "splash"
    "boot.shell_on_fail"
    "udev.log_priority=3"
    "rd.systemd.show_status=auto"
  ];


  # Enable experimental features for flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  
  # Automatic garbage collection - enabled for system maintenance
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  
  # Automatic system updates every other day - enabled for system maintenance
  systemd.timers.auto-upgrade = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31 02:00:00";
      Persistent = true;
    };
  };
  
  systemd.services.auto-upgrade = {
    serviceConfig.Type = "oneshot";
    script = ''
      cd /home/aragao/projects/personal/nix
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake .#parallels-nixos --upgrade-all
    '';
  };
  
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tree
    uwsm
    claude-code
    inotify-tools  # For file monitoring in auto-rebuild script
    psmisc  # Provides killall command
    nettools  # Provides netstat, ifconfig, route, etc.
    smem  # Memory usage reporting tool
    procps  # Provides vmstat, slabtop, and other system utilities
    lsof  # List open files and network connections
    bc  # Basic calculator for command line calculations
    
    # LSP servers and development tools (needed for both user and root Neovim)
    nil  # Nix LSP
    nixfmt-rfc-style  # Nix formatter
    bash-language-server
    marksman  # Markdown LSP
    pyright  # Python LSP
    gopls  # Go LSP  
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted  # HTML/CSS/JSON/ESLint LSPs
    jdt-language-server  # Java LSP
    
    # Programming languages and runtimes (for LSP functionality)
    python3
    go
    nodejs_22
    openjdk21
    
    # Rust-based CLI replacements for coreutils (system-wide)
    ripgrep      # rg - faster grep replacement
    fd           # fd - user-friendly find replacement
    bat          # cat with syntax highlighting
    eza          # ls replacement with colors and icons
    lsd          # alternative ls with colors and icons
    dust         # du replacement
    zoxide       # smart cd command
    bottom       # btm - top/htop replacement
    delta        # git diff with syntax highlighting
    procs        # ps replacement
    hyperfine    # benchmarking tool (time replacement)
    bandwhich    # network utilization by process
    dog          # dns lookup tool (dig replacement)
    tokei        # fast code line counter
    uutils-coreutils  # Complete Rust coreutils implementation
    
    # Additional modern CLI tools
    duf          # df replacement
    broot        # interactive tree view
    sd           # sed replacement
    choose       # cut replacement
    hexyl        # hex viewer
    grex         # regex generator from examples
    
    # Audio/Video control tools (needed for simplified media keys)
    pamixer      # PulseAudio/PipeWire mixer
    brightnessctl # Brightness control
    
    # X11 packages moved to x11-dwm.nix module
  ];

  # Enable Hyprland from flake with UWSM
  programs.hyprland = {
    enable = true;
    package = inputs.hyprland.packages.${pkgs.system}.hyprland;
    portalPackage = inputs.hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
    withUWSM = true;  # Use Universal Wayland Session Manager
    xwayland.enable = true;
  };

  # Enable Sway (DISABLED - redundant with Hyprland, only one compositor needed)
  # programs.sway = {
  #   enable = true;
  #   package = pkgs.sway;
  #   wrapperFeatures.gtk = true;
  #   xwayland.enable = false;
  #   extraPackages = with pkgs; [
  #     swaylock
  #     swayidle
  #     swaybg
  #     wl-clipboard
  #     wlogout
  #     wofi
  #   ];
  # };

  xdg.portal = {
    enable = true;
    config.common.default = "*";
  };

  # Docker (DISABLED - only enable if you need containers)
  # virtualisation.docker.enable = true;
  
  # Audio with PipeWire
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };
  
  # Disable conflicting audio services
  services.pulseaudio.enable = false;  # Explicitly disable PulseAudio (conflicts with PipeWire)

  # Use greetd as the display manager with session selection
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --remember-user-session";
        user = "greeter";
      };
    };
  };
  
  # Set default session for X11

  # X11 server and input configuration moved to x11-dwm.nix module

  # Picom configuration moved to x11-dwm.nix module


  # Greetd is already configured as display manager above
  # services.displayManager.enable = true;  # Commented out - conflicts with greetd

  # User configuration
  users.users.aragao = {
    isNormalUser = true;
    description = "Andre Aragao";
    extraGroups = [ "wheel" "networkmanager" "audio" "video" ];  # Removed "docker" since it's disabled
    shell = pkgs.zsh;
  };

  # Enable zsh system-wide
  programs.zsh.enable = true;

  # Virtualization support - Parallels and QEMU guest modules
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;  # Enhanced clipboard and display for VMs
  services.upower.enable = true;

  # Network configuration
  networking.hostName = "parallels-nixos";
  networking.networkmanager.enable = true;

  # Time zone and locale
  time.timeZone = "America/Denver";  # Denver timezone
  i18n.defaultLocale = "en_US.UTF-8";

  # SSH (DISABLED - only enable if you need remote access)
  # services.openssh = {
  #   enable = true;
  #   settings = {
  #     PasswordAuthentication = false;
  #     KbdInteractiveAuthentication = false;
  #   };
  # };

  # Sudo configuration
  security.sudo = {
    enable = true;
    extraConfig = ''
      Defaults timestamp_timeout=60
      # Allow aragao to run nixos-rebuild without password for auto-rebuild service
      aragao ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild
    '';
  };

  # GTK theme configuration and system-wide environment variables
  environment.sessionVariables = {
    GTK_THEME = "Adwaita:dark";
    WLR_NO_HARDWARE_CURSORS = "1";  # Enable hardware cursors for better performance
  };
  
  programs.dconf.enable = true;
  
  # Fonts
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    yaru-theme
  ];

  # Configure temporary filesystems to use disk instead of RAM
  boot.tmp.useTmpfs = false;  # Disable tmpfs for /tmp
  boot.tmp.cleanOnBoot = true;  # Clean /tmp on boot

  # System-level log rotation for auto-rebuild logs - enabled for system maintenance
  services.logrotate = {
    enable = true;
    settings = {
      "/home/aragao/projects/personal/nix/auto-rebuild.log" = {
        frequency = "weekly";
        rotate = 8;  # Keep 8 weeks of logs
        compress = true;
        delaycompress = true;
        missingok = true;
        notifempty = true;
        create = "644 aragao users";
        postrotate = "systemctl --user restart nixos-auto-rebuild.service || true";
      };
    };
  };

  system.stateVersion = "24.11";
  }; # End of config block
}
