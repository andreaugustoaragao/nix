{
  description = "NixOS configuration for Parallels VM with Hyprland";
  #
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    {
      nixosConfigurations.parallels-nixos = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux"; # Change to x86_64-linux if using Intel Mac
        specialArgs = { inherit inputs; };
        modules = [
          ./configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.aragao = import ./home;
            home-manager.extraSpecialArgs = { inherit inputs; };
            # Use timestamp-based backup extension to avoid conflicts
            home-manager.backupFileExtension = "hm-backup-$(date +%Y%m%d-%H%M%S)";
          }
        ];
      };
    };
}
