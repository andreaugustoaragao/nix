{
  config,
  pkgs,
  lib,
  stateVersion,
  ...
}:
{
  imports = [
    ./sops.nix
    ./ethernet.nix
    ./nginx.nix
    ./certs.nix
    ./smb.nix
    ./monitoring.nix
    ./vaultwarden.nix
    ./matrix.nix
    ./upgrade.nix
    ./tmux.nix
    ./verify.nix
  ];

  nix = {
    package = pkgs.nixVersions.stable;
    optimise.automatic = true;

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  nixpkgs.config.allowUnfree = true;

  # Set your time zone.
  time.timeZone = "America/Denver";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  users.mutableUsers = false;

  users.users.root.hashedPasswordFile = config.sops.secrets.root_password.path;

  users.users.adm = {
    uid = 1000;
    isNormalUser = true;
    description = "main";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    hashedPasswordFile = config.sops.secrets.adm_password.path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJrYiSHjifZ0OVdRDRirJRxxy7M/fzBHA88n4O8L3uYv aragao@workstation"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCjMOE5ENVkFQpYiss3n0zjuA1insKR5nwUmbT21jS/vVv/m94w6Rxpi42hwUPiFZ+bjlZGME6pXJKBDrBdrO65Ag/ahFc9B5LTwVOaD4GM17FR80nCyGx6gGkDix9T+tOA322o+DJGTWIwjF0LWFsdwIXkl845aN01LYNqV6NgHIpC+tq6Yj+KZE+0xDE//l150WPwoBF0vcoMxqXJ64GHeVff+h9/GQcEhAVIQfloxLOWca/Wa+BNxcwXwvUwyRVYeMAqVxqV1WRIJCvC/pIqUeCkn1Xm3LhEm9sKJ7kI+V2vsr1gECyb8lRlB7c4nqj9xH11hpDtFfGUGNTXKfpPgtq4DDGOb/8pgr7EWmkJc9V/HgNQ9/P1A+MSqyn+60Bt4WcxytP9vydsNQdyQCrZFVtrm+6jHOnK0P8NgANJWPzb8pyUmaSn/Lg1ghfYwSj/+CXVyHWl5oegAACtvSORWDYQMCFBn8SWxsAPfvtU/BPBPKue1LasgaNzoDCWBzTnVAVWDLbb3oxt+M5AEJ81zyPlC9Dz/5/CSJeFsV4aXZyJ0DkjHuIX/bEk/Wvz5cBPCqcLcOrKt7eShCwiqAhdDuErZhhHuVW3bLGnXmEdQZzmC0TTTChV6T9bU1BqfvntZMfOEQ7NPZSO7aVItSeqoL/3EygpQig08OZ9hjjmoQ== aragao@avaya.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECX5xCCeHXtKMa98SL3Z6ZLDVkQdLKD7hcywXNjlWcm andrearag@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIeolxe+QbSS7V8ub29UsTPwZEc/kJ9c8xClsVd0PByA aragao@avaya.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBwxAV1dHcO6/w1TGKphpkWtnWejVj/A56xM2AhHXQhr netadmin@workstation-2026-11-26"
    ];
  };

  users.users.tehfiti = {
    uid = 1002;
    isNormalUser = true;
    description = "goddess";
    extraGroups = [ "networkmanager" ];
    hashedPassword = "!";
  };

  users.users.backup = {
    uid = 1003;
    isNormalUser = true;
    description = "";
    extraGroups = [ ];
    hashedPassword = "!";
  };

  xdg.icons.enable = false;
  xdg.mime.enable = false;
  xdg.sounds.enable = false;
  documentation.man.enable = false;
  environment.defaultPackages = lib.mkForce [ ];
  environment.systemPackages = with pkgs; [
    sops
    age
    curl
    sqlite
    fastfetch
    fortune
    git
    htop
    entr
    fd
    alejandra
    nil
    ripgrep
    jq
    shfmt
    busybox
    btrfs-progs
    eza
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };

  programs.htop = {
    enable = true;
    settings = {
      hide_kernel_threads = true;
      hide_userland_threads = true;
    };
  };

  programs.fzf = {
    keybindings = true;
    fuzzyCompletion = true;
  };

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  #to enable special font in kmscon
  fonts.fontconfig.enable = lib.mkForce true;
  fonts.packages = [ pkgs.nerd-fonts.droid-sans-mono ];
  hardware.graphics.enable = true;
  services.kmscon = {
    enable = true;
    config = {
      font-name = "DroidSansM Nerd Font Mono";
      font-size = 12;
      hwaccel = true;
    };
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      fish_vi_key_bindings
      function fish_greeting
        fastfetch
        fortune
      end
    '';
    shellAliases = {
      ls = "eza --icons";
      ll = "eza --icons --group-directories-first -al";
      vi = "nvim";
      v = "nvim";
      vim = "nvim";
    };
  };

  programs.starship = {
    enable = true;
  };

  system.stateVersion = stateVersion;
}
