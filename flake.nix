{
  description = "NixOS configuration for Parallels VM with Hyprland";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Tracks the nixpkgs-unstable branch (not nixos-unstable). Both are
    # channel-tested; nixpkgs-unstable rolls slightly faster and is
    # currently the one carrying Go 1.26.2 (nixos-unstable is lagging
    # on 1.26.1 as of this writing). Needed so lfk, which requires
    # Go >= 1.26.2, can build.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

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

    lfk = {
      url = "github:janosmiko/lfk";
      # lfk's `vendorHash` is computed against the exact nixpkgs rev
      # pinned in its own flake.lock. Upstream declares
      # `nixpkgs.url = "github:NixOS/nixpkgs/master"` (a moving branch),
      # so without this explicit pin every `nix flake update` would
      # re-resolve lfk's nixpkgs to a newer master tip whose
      # buildGoModule produces a different vendor hash. Pinning to the
      # exact commit upstream tested with keeps the build reproducible.
      inputs.nixpkgs.url =
        "github:NixOS/nixpkgs/9cadaf6932b7c926e468f777549d57f04a7212da";
    };

    claude-code = {
      url = "github:sadjow/claude-code-nix";
    };

    zed-editor = {
      url = "github:zed-industries/zed";
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
      nixosConfigurations = (
        builtins.mapAttrs (
          machineName: host:
          nixpkgs.lib.nixosSystem {
            specialArgs = setSpecialArgs host;
            modules = [
              { nixpkgs.hostPlatform = host.platform; }
              { nixpkgs.overlays = [ claude-code.overlays.default ]; }
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
