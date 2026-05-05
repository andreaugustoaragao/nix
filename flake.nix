{
  description = "NixOS configuration for Parallels VM with Hyprland";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Tracks nixpkgs-unstable for packages we want fresher than 25.11
    # (niri, zellij, pipewire). See `unstable-pkgs` consumers across
    # system/ and home/.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Pinned to nixos-25.05 solely to keep xdg-desktop-portal-gnome at
    # version 48.x. GNOME 49 added a hard requirement on
    # org.gnome.Mutter.ServiceChannel that the niri 26.04 in nixpkgs
    # doesn't yet expose, which sends the gnome portal into
    # "Non-compatible display server, exposing settings only" mode and
    # breaks ScreenCast/RemoteDesktop/Screenshot. Drop this input once
    # niri implements ServiceChannel.
    nixpkgs-gnome48.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code = {
      url = "github:sadjow/claude-code-nix";
    };

    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      firefox-addons,
      sops-nix,
      claude-code,

      ...
    }@inputs:
    let
      metadata = builtins.fromTOML (builtins.readFile ./machines.toml);
      lib = nixpkgs.lib;

      # Get username for the platform
      getUserName = user: host: user.name;

      # Set special args for each machine
      setSpecialArgs = host: {
        isWorkstation = (host.profile == "workstation");
        isLaptop = (host.profile == "laptop");
        isVm = (host.profile == "vm");
        isServer = (host.profile == "server");
        owner = metadata.user // {
          name = getUserName metadata.user host;
        };
        inherit (host) hostName stateVersion profile;
        # Optional wireless configuration
        wirelessInterface = host.wirelessInterface or null;
        # Optional bluetooth configuration
        bluetooth = host.bluetooth or false;
        # Optional lock screen configuration
        lockScreen = host.lockScreen or false;
        # Optional auto login configuration
        autoLogin = host.autoLogin or false;
        # Enable DankMaterialShell on this host. When true, conflicting
        # daemons (waybar, mako, hyprpaper, swayidle, swayosd,
        # hyprpolkitagent) are not autostarted so DMS owns the screen.
        useDms = host.useDms or false;
        inherit inputs;
      };

      # Set Home Manager template
      setHomeManagerTemplate = host: {
        home-manager = {
          useUserPackages = true;
          useGlobalPkgs = true;
          extraSpecialArgs = setSpecialArgs host;
          users.${getUserName metadata.user host} = import ./home;
          backupFileExtension = "hm-backup";
        };
      };
    in
    {
      # NixOS configurations for all machines
      nixosConfigurations = (
        builtins.mapAttrs (
          machineName: host:
          nixpkgs.lib.nixosSystem {
            specialArgs = setSpecialArgs host;
            modules = [
              { nixpkgs.hostPlatform = host.platform; }
              {
                nixpkgs.overlays = [
                  claude-code.overlays.default
                  # See nixpkgs-gnome48 input above for the why.
                  (final: prev: {
                    xdg-desktop-portal-gnome =
                      inputs.nixpkgs-gnome48.legacyPackages.${host.platform}.xdg-desktop-portal-gnome;
                  })
                ];
              }
              # Hardware configuration
              (./hardware + "/${machineName}" + /hardware-configuration.nix)
              # System configuration
              ./system
              # Secrets management
              sops-nix.nixosModules.sops
              # Home Manager configuration
              home-manager.nixosModules.home-manager
              (setHomeManagerTemplate host)
            ];
          }
        ) metadata.machines
      );
    };
}
