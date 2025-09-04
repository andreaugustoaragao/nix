{
  description = "NixOS configuration for Parallels VM with Hyprland";
  #
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland = {
      url = "github:hyprwm/Hyprland/v0.49.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    hyprland,
    ...
  } @ inputs: {
    # Define overlay for custom packages
    overlays.default = final: prev: {
      polybar-dwm-module = prev.stdenv.mkDerivation rec {
        pname = "polybar-dwm-module";
        version = "1.0.0";
        
        src = prev.fetchgit {
          url = "https://github.com/mihirlad55/polybar-dwm-module.git";
          rev = "de3748122fa50e9c022675463b69a2f8ae4f43a3";
          sha256 = "sha256-xFk8XYVRvvHXw0DtZ+IXrIYOEJHM+ldUWSJau9FfLIM=";
          fetchSubmodules = true;
        };
        
        nativeBuildInputs = with prev; [
          cmake
          pkg-config
        ];
        
        buildInputs = with prev; [
          polybar
          jsoncpp
          # X11 and XCB dependencies
          xorg.xcbproto
          xorg.xcbutil
          xorg.xcbutilwm
          xorg.xcbutilimage
          xorg.xcbutilrenderutil
          xorg.xcbutilcursor
          xorg.libxcb
          xorg.libXau
          xorg.libXdmcp
          # Cairo dependencies
          cairo
          pango
          # Additional Polybar dependencies
          libuv
          curl
          alsa-lib
          libpulseaudio
          i3
          python3
        ];
        
        cmakeFlags = [
          "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"
        ];
        
        meta = with prev.lib; {
          description = "A dwm module for polybar";
          homepage = "https://github.com/mihirlad55/polybar-dwm-module";
          license = licenses.mit;
          platforms = platforms.linux;
        };
      };
    };
    
    # Expose packages from overlay
    packages.aarch64-linux = {
      polybar-dwm-module = (nixpkgs.legacyPackages.aarch64-linux.extend self.overlays.default).polybar-dwm-module;
    };
    
    nixosConfigurations.parallels-nixos = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux"; # Change to x86_64-linux if using Intel Mac
      specialArgs = {inherit inputs;};
      modules = [
        ./configuration.nix
        # Apply our overlay
        ({ config, pkgs, ... }: { nixpkgs.overlays = [ self.overlays.default ]; })
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.aragao = import ./home.nix;
          home-manager.extraSpecialArgs = {inherit inputs;};
          home-manager.backupFileExtension = "backup";
        }
      ];
    };
  };
}

