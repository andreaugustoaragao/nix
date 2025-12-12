{
  description = "NixOS configuration for Parallels VM with Hyprland";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

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

  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      firefox-addons,
      sops-nix,
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
        inherit inputs;
      };

      # Set Home Manager template
      setHomeManagerTemplate = host: {
        home-manager = {
          useUserPackages = true;
          useGlobalPkgs = true;
          extraSpecialArgs = setSpecialArgs host;
          users.${getUserName metadata.user host} = import ./home;
          backupFileExtension = "hm-backup-$(date +%Y%m%d-%H%M%S)";
        };
      };
    in
    {
      # NixOS configurations for all machines
      nixosConfigurations =
        (builtins.mapAttrs (
          machineName: host:
          nixpkgs.lib.nixosSystem {
            system = host.platform;
            specialArgs = setSpecialArgs host;
            modules = [
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
        ) metadata.machines)
        // {
          # Temporary backward compatibility alias for current hostname
          "parallels-nixos" = nixpkgs.lib.nixosSystem {
            system = metadata.machines.parallels-vm.platform;
            specialArgs = setSpecialArgs metadata.machines.parallels-vm;
            modules = [
              # Hardware configuration
              (./hardware + "/parallels-vm" + /hardware-configuration.nix)
              # System configuration
              ./system
              # Secrets management
              sops-nix.nixosModules.sops
              # Home Manager configuration
              home-manager.nixosModules.home-manager
              (setHomeManagerTemplate metadata.machines.parallels-vm)
            ];
          };
        };
    };
}
